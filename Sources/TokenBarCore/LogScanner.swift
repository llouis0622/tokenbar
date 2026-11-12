import Foundation

struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date
}

enum LogFiles {
    static func jsonl(under root: URL, modifiedAfter cutoff: Date) -> [(url: URL, stamp: FileStamp)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var found: [(url: URL, stamp: FileStamp)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            found.append((url, FileStamp(size: UInt64(max(values.fileSize ?? 0, 0)), modified: modified)))
        }
        return found
    }
}

enum LineReader {
    static let chunkSize = 1 << 20
    static let maxLineBytes = 32 << 20

    static func read(_ url: URL, from offset: UInt64, needles: [[UInt8]], body: ([String: Any]) -> Void) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return offset
        }
        var consumed = offset
        var pending = Data()
        var skipping = false
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            pending.append(chunk)
            autoreleasepool {
                var used = 0
                pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    while used < raw.count {
                        guard let hit = memchr(base + used, 0x0A, raw.count - used) else { break }
                        let length = (base + used).distance(to: UnsafeRawPointer(hit))
                        if skipping {
                            skipping = false
                        } else if length > 0, matches(base + used, length, needles) {
                            let line = Data(bytes: base + used, count: length)
                            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                body(object)
                            }
                        }
                        used += length + 1
                    }
                }
                consumed += UInt64(used)
                pending.removeSubrange(pending.startIndex..<pending.startIndex + used)
                if pending.count > maxLineBytes {
                    consumed += UInt64(pending.count)
                    pending.removeAll(keepingCapacity: false)
                    skipping = true
                }
            }
        }
        return consumed
    }

    private static func matches(_ start: UnsafeRawPointer, _ length: Int, _ needles: [[UInt8]]) -> Bool {
        for needle in needles {
            let found = needle.withUnsafeBytes { memmem(start, length, $0.baseAddress, $0.count) != nil }
            if found { return true }
        }
        return false
    }
}

struct CompactRecord {
    var key: UInt64
    var time: UInt32
    var model: UInt16
    var input: UInt32
    var output: UInt32
    var write5m: UInt32
    var write1h: UInt32
    var cacheRead: UInt32

    var usage: TokenUsage {
        TokenUsage(
            input: Int(input),
            output: Int(output),
            cacheWrite5m: Int(write5m),
            cacheWrite1h: Int(write1h),
            cacheRead: Int(cacheRead)
        )
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(time))
    }
}

final class ModelTable {
    private var names: [String] = []
    private var indexes: [String: UInt16] = [:]

    func index(_ name: String) -> UInt16 {
        if let known = indexes[name] { return known }
        if names.count >= Int(UInt16.max) { return 0 }
        let index = UInt16(names.count)
        names.append(name)
        indexes[name] = index
        return index
    }

    func name(_ index: UInt16) -> String {
        Int(index) < names.count ? names[Int(index)] : "unknown"
    }
}

enum Hashing {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

struct CodexState {
    var model = "gpt-5"
    var previous: CodexLogScanner.Counters?
}

struct CachedFile {
    var stamp: FileStamp
    var offset: UInt64 = 0
    var records: [CompactRecord] = []
    var codex = CodexState()
}

final class ClaudeLogScanner {
    private var cache: [String: CachedFile] = [:]
    private let roots: [URL]
    private let models = ModelTable()
    private static let needles = [Array("\"usage\"".utf8)]

    init(home: URL) {
        var roots = [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        self.roots = roots
    }

    private func refresh(since cutoff: Date) {
        var live: [String: CachedFile] = [:]
        let table = models
        for root in roots {
            for file in LogFiles.jsonl(under: root, modifiedAfter: cutoff) {
                let path = file.url.path
                if let cached = cache[path], cached.stamp == file.stamp {
                    live[path] = cached
                    continue
                }
                var start: UInt64 = 0
                var records: [CompactRecord] = []
                if let cached = cache[path], file.stamp.size >= cached.offset {
                    start = cached.offset
                    records = cached.records
                }
                let end = LineReader.read(file.url, from: start, needles: Self.needles) { object in
                    guard let record = Self.record(from: object, models: table, fallbackKey: UInt64(records.count)) else { return }
                    if let duplicate = records.suffix(16).lastIndex(where: { $0.key == record.key }) {
                        records[duplicate] = record
                    } else {
                        records.append(record)
                    }
                }
                live[path] = CachedFile(stamp: file.stamp, offset: end, records: records)
            }
        }
        cache = live
    }

    func collect(since cutoff: Date, into aggregate: inout UsageAggregate) {
        refresh(since: cutoff)
        let floor = UInt32(clamping: Int(cutoff.timeIntervalSince1970))
        var merged: [UInt64: CompactRecord] = [:]
        for path in cache.keys.sorted() {
            for record in cache[path]?.records ?? [] where record.time >= floor {
                merged[record.key] = record
            }
        }
        for record in merged.values {
            aggregate.add(provider: .claude, model: models.name(record.model), timestamp: record.date, usage: record.usage)
        }
    }

    var cachedRecordCount: Int {
        cache.values.reduce(0) { $0 + $1.records.count }
    }

    static func record(from object: [String: Any], models: ModelTable, fallbackKey: UInt64) -> CompactRecord? {
        guard object["type"] as? String == "assistant",
              let message = object.dict("message"),
              let usage = message.dict("usage"),
              let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse)
        else { return nil }
        let model = message["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return nil }
        let created = usage.int("cache_creation_input_tokens")
        var write5m = created
        var write1h = 0
        if let detail = usage.dict("cache_creation") {
            write1h = detail.int("ephemeral_1h_input_tokens")
            write5m = max(detail.int("ephemeral_5m_input_tokens"), created - write1h)
        }
        var record = CompactRecord(
            key: 0,
            time: UInt32(clamping: Int(stamp.timeIntervalSince1970)),
            model: models.index(model),
            input: UInt32(clamping: usage.int("input_tokens")),
            output: UInt32(clamping: usage.int("output_tokens")),
            write5m: UInt32(clamping: write5m),
            write1h: UInt32(clamping: write1h),
            cacheRead: UInt32(clamping: usage.int("cache_read_input_tokens"))
        )
        guard record.usage.total > 0 else { return nil }
        if let messageId = message["id"] as? String {
            let scope = object["requestId"] as? String ?? object["sessionId"] as? String ?? ""
            record.key = Hashing.fnv1a(messageId + ":" + scope)
        } else {
            record.key = Hashing.fnv1a("loose:\(record.time):\(fallbackKey)")
        }
        return record
    }
}

final class CodexLogScanner {
    struct Counters {
        var input: Int
        var cached: Int
        var output: Int

        init(input: Int, cached: Int, output: Int) {
            self.input = input
            self.cached = cached
            self.output = output
        }

        init(_ usage: [String: Any]) {
            self.init(
                input: usage.int("input_tokens"),
                cached: usage.int("cached_input_tokens"),
                output: usage.int("output_tokens")
            )
        }
    }

    private var cache: [String: CachedFile] = [:]
    private let codexHome: URL
    private let models = ModelTable()
    private static let needles = [Array("\"token_count\"".utf8), Array("\"turn_context\"".utf8)]
    private static let limitNeedles = [Array("\"rate_limits\"".utf8)]

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    private var roots: [URL] {
        [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
    }

    func collect(since cutoff: Date, into aggregate: inout UsageAggregate) {
        var live: [String: CachedFile] = [:]
        let table = models
        for root in roots {
            for file in LogFiles.jsonl(under: root, modifiedAfter: cutoff) {
                let path = file.url.path
                if let cached = cache[path], cached.stamp == file.stamp {
                    live[path] = cached
                    continue
                }
                var start: UInt64 = 0
                var records: [CompactRecord] = []
                var state = CodexState()
                if let cached = cache[path], file.stamp.size >= cached.offset {
                    start = cached.offset
                    records = cached.records
                    state = cached.codex
                }
                let end = LineReader.read(file.url, from: start, needles: Self.needles) { object in
                    if let record = Self.record(from: object, state: &state, models: table) {
                        records.append(record)
                    }
                }
                live[path] = CachedFile(stamp: file.stamp, offset: end, records: records, codex: state)
            }
        }
        cache = live
        let floor = UInt32(clamping: Int(cutoff.timeIntervalSince1970))
        for entry in live.values {
            for record in entry.records where record.time >= floor {
                aggregate.add(provider: .codex, model: models.name(record.model), timestamp: record.date, usage: record.usage)
            }
        }
    }

    static func record(from object: [String: Any], state: inout CodexState, models: ModelTable) -> CompactRecord? {
        guard let payload = object.dict("payload") else { return nil }
        let type = object["type"] as? String
        if type == "turn_context" {
            if let name = payload["model"] as? String, !name.isEmpty { state.model = name }
            return nil
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload.dict("info"),
              let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse)
        else { return nil }
        let last = info.dict("last_token_usage").map { Counters($0) }
        var delta: Counters?
        if let total = info.dict("total_token_usage") {
            let current = Counters(total)
            if let before = state.previous {
                let step = Counters(
                    input: current.input - before.input,
                    cached: current.cached - before.cached,
                    output: current.output - before.output
                )
                if step.input >= 0, step.cached >= 0, step.output >= 0 {
                    delta = step
                } else {
                    delta = last ?? current
                }
            } else {
                delta = current
            }
            state.previous = current
        } else {
            delta = last
        }
        guard let step = delta, step.input + step.output > 0 else { return nil }
        let cached = min(step.cached, step.input)
        return CompactRecord(
            key: 0,
            time: UInt32(clamping: Int(stamp.timeIntervalSince1970)),
            model: models.index(state.model),
            input: UInt32(clamping: step.input - cached),
            output: UInt32(clamping: step.output),
            write5m: 0,
            write1h: 0,
            cacheRead: UInt32(clamping: cached)
        )
    }

    func latestRateLimits(now: Date) -> LimitSnapshot? {
        let recent = roots
            .flatMap { LogFiles.jsonl(under: $0, modifiedAfter: now.addingTimeInterval(-8 * 86_400)) }
            .sorted { $0.stamp.modified > $1.stamp.modified }
            .prefix(5)
        var best: LimitSnapshot?
        let tail: UInt64 = 512 * 1024
        for file in recent {
            let start = file.stamp.size > tail ? file.stamp.size - tail : 0
            var latest: LimitSnapshot?
            _ = LineReader.read(file.url, from: start, needles: Self.limitNeedles) { object in
                if let snapshot = Self.rateLimits(from: object) {
                    latest = snapshot
                }
            }
            if let latest, best == nil || latest.fetchedAt > best!.fetchedAt {
                best = latest
            }
        }
        return best
    }

    static func rateLimits(from object: [String: Any]) -> LimitSnapshot? {
        guard let payload = object.dict("payload"),
              let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse),
              let limits = payload.dict("rate_limits") ?? payload.dict("info")?.dict("rate_limits")
        else { return nil }
        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = limits.dict(key), let used = window.double("used_percent") else { continue }
            var resetsAt: Date?
            if let epoch = window.double("resets_at"), epoch > 0 {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = window.double("resets_in_seconds") {
                resetsAt = stamp.addingTimeInterval(after)
            }
            let label = Format.windowLabel(seconds: window.int("window_minutes") * 60)
            windows.append(LimitWindow(label: label, usedPercent: used, resetsAt: resetsAt))
        }
        guard !windows.isEmpty else { return nil }
        return LimitSnapshot(provider: .codex, windows: windows, plan: nil, fetchedAt: stamp, source: .localLog)
    }
}

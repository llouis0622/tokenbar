import Foundation

struct FileStamp: Equatable {
    let size: Int
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
            found.append((url, FileStamp(size: values.fileSize ?? 0, modified: modified)))
        }
        return found
    }

    static func lines(of url: URL, containing needles: [Data]) -> [[String: Any]] {
        guard let content = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var objects: [[String: Any]] = []
        for line in content.split(separator: 0x0A) {
            guard needles.contains(where: { line.range(of: $0) != nil }) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                objects.append(object)
            }
        }
        return objects
    }
}

struct ClaudeRecord {
    let key: String?
    let entry: UsageEntry
}

final class ClaudeLogScanner {
    private var cache: [String: (stamp: FileStamp, records: [ClaudeRecord])] = [:]
    private let roots: [URL]
    private static let needle = [Data("\"usage\"".utf8)]

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

    func entries(since cutoff: Date) -> [UsageEntry] {
        var live: [String: (stamp: FileStamp, records: [ClaudeRecord])] = [:]
        for root in roots {
            for file in LogFiles.jsonl(under: root, modifiedAfter: cutoff) {
                let path = file.url.path
                if let cached = cache[path], cached.stamp == file.stamp {
                    live[path] = cached
                } else {
                    live[path] = (file.stamp, Self.parse(file.url))
                }
            }
        }
        cache = live
        var keyed: [String: UsageEntry] = [:]
        var loose: [UsageEntry] = []
        for path in live.keys.sorted() {
            for record in live[path]?.records ?? [] where record.entry.timestamp >= cutoff {
                if let key = record.key {
                    keyed[key] = record.entry
                } else {
                    loose.append(record.entry)
                }
            }
        }
        return Array(keyed.values) + loose
    }

    static func parse(_ url: URL) -> [ClaudeRecord] {
        var records: [ClaudeRecord] = []
        for object in LogFiles.lines(of: url, containing: needle) {
            guard object["type"] as? String == "assistant",
                  let message = object.dict("message"),
                  let usage = message.dict("usage"),
                  let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse)
            else { continue }
            let model = message["model"] as? String ?? "unknown"
            if model == "<synthetic>" { continue }
            let created = usage.int("cache_creation_input_tokens")
            var write5m = created
            var write1h = 0
            if let detail = usage.dict("cache_creation") {
                write1h = detail.int("ephemeral_1h_input_tokens")
                write5m = max(detail.int("ephemeral_5m_input_tokens"), created - write1h)
            }
            let tokens = TokenUsage(
                input: usage.int("input_tokens"),
                output: usage.int("output_tokens"),
                cacheWrite5m: max(write5m, 0),
                cacheWrite1h: write1h,
                cacheRead: usage.int("cache_read_input_tokens")
            )
            guard tokens.total > 0 else { continue }
            var key: String?
            if let messageId = message["id"] as? String {
                let scope = object["requestId"] as? String ?? object["sessionId"] as? String ?? ""
                key = messageId + ":" + scope
            }
            records.append(ClaudeRecord(key: key, entry: UsageEntry(provider: .claude, model: model, timestamp: stamp, usage: tokens)))
        }
        return records
    }
}

final class CodexLogScanner {
    private var cache: [String: (stamp: FileStamp, entries: [UsageEntry])] = [:]
    private let codexHome: URL
    private static let needles = [Data("\"token_count\"".utf8), Data("\"turn_context\"".utf8)]

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    private var roots: [URL] {
        [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
    }

    func entries(since cutoff: Date) -> [UsageEntry] {
        var live: [String: (stamp: FileStamp, entries: [UsageEntry])] = [:]
        for root in roots {
            for file in LogFiles.jsonl(under: root, modifiedAfter: cutoff) {
                let path = file.url.path
                if let cached = cache[path], cached.stamp == file.stamp {
                    live[path] = cached
                } else {
                    live[path] = (file.stamp, Self.parse(file.url))
                }
            }
        }
        cache = live
        return live.values.flatMap { $0.entries }.filter { $0.timestamp >= cutoff }
    }

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

    static func parse(_ url: URL) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        var model = "gpt-5"
        var previous: Counters?
        for object in LogFiles.lines(of: url, containing: needles) {
            guard let payload = object.dict("payload") else { continue }
            let type = object["type"] as? String
            if type == "turn_context" {
                if let name = payload["model"] as? String, !name.isEmpty { model = name }
                continue
            }
            guard type == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload.dict("info"),
                  let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse)
            else { continue }
            let last = info.dict("last_token_usage").map { Counters($0) }
            var delta: Counters?
            if let total = info.dict("total_token_usage") {
                let current = Counters(total)
                if let before = previous {
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
                previous = current
            } else {
                delta = last
            }
            guard let step = delta else { continue }
            let cached = min(step.cached, step.input)
            let tokens = TokenUsage(input: step.input - cached, output: step.output, cacheRead: cached)
            guard tokens.total > 0 else { continue }
            entries.append(UsageEntry(provider: .codex, model: model, timestamp: stamp, usage: tokens))
        }
        return entries
    }

    func latestRateLimits(now: Date) -> LimitSnapshot? {
        let recent = roots
            .flatMap { LogFiles.jsonl(under: $0, modifiedAfter: now.addingTimeInterval(-8 * 86_400)) }
            .sorted { $0.stamp.modified > $1.stamp.modified }
            .prefix(5)
        var best: LimitSnapshot?
        for file in recent {
            for object in LogFiles.lines(of: file.url, containing: [Data("\"rate_limits\"".utf8)]).reversed() {
                guard let payload = object.dict("payload"),
                      let stamp = (object["timestamp"] as? String).flatMap(DateParsing.parse),
                      let limits = payload.dict("rate_limits") ?? payload.dict("info")?.dict("rate_limits")
                else { continue }
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
                guard !windows.isEmpty else { continue }
                if best == nil || stamp > best!.fetchedAt {
                    best = LimitSnapshot(provider: .codex, windows: windows, plan: nil, fetchedAt: stamp, source: .localLog)
                }
                break
            }
        }
        return best
    }
}

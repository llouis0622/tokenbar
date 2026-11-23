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

final class CodexLogScanner {
    private let codexHome: URL
    private static let limitNeedles = [Array("\"rate_limits\"".utf8)]

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    private var roots: [URL] {
        [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
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

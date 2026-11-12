import Foundation

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let plan: String?
}

public enum ClaudeCredentialStore {
    static let keychainService = "Claude Code-credentials"

    public static func parse(_ raw: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = root.dict("claudeAiOauth"),
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let millis = oauth.double("expiresAt") {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, plan: oauth["subscriptionType"] as? String)
    }

    public static func load(home: URL) -> ClaudeCredentials? {
        var candidates: [ClaudeCredentials] = []
        #if os(macOS)
        if let raw = readKeychain(), let parsed = parse(raw) {
            candidates.append(parsed)
        }
        #endif
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let raw = try? Data(contentsOf: file), let parsed = parse(raw) {
            candidates.append(parsed)
        }
        return candidates.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    #if os(macOS)
    static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !raw.isEmpty else { return nil }
        return raw
    }
    #endif
}

public struct ClaudeLimitFetcher: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let windowKeys: [(key: String, label: String)] = [
        ("five_hour", "5시간"),
        ("seven_day", "주간"),
        ("seven_day_opus", "주간 Opus"),
        ("seven_day_sonnet", "주간 Sonnet"),
    ]

    let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func fetch(using credentials: ClaudeCredentials, now: Date = Date()) async throws -> LimitSnapshot {
        let result = try await client.get(url: Self.endpoint, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "TokenBar",
        ])
        try LimitError.check(result, provider: .claude)
        return try Self.parse(result.data, plan: credentials.plan, now: now)
    }

    public static func parse(_ body: Data, plan: String?, now: Date) throws -> LimitSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LimitError.badResponse
        }
        var windows: [LimitWindow] = []
        for item in windowKeys {
            guard let window = root.dict(item.key), let used = window.double("utilization") else { continue }
            let resetsAt = (window["resets_at"] as? String).flatMap(DateParsing.parse)
            windows.append(LimitWindow(label: item.label, usedPercent: used, resetsAt: resetsAt))
        }
        guard !windows.isEmpty else { throw LimitError.badResponse }
        return LimitSnapshot(provider: .claude, windows: windows, plan: plan, fetchedAt: now, source: .api)
    }
}

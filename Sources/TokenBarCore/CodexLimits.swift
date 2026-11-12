import Foundation

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String?
}

public enum CodexPaths {
    public static func home(userHome: URL) -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return userHome.appendingPathComponent(".codex")
    }
}

public enum CodexCredentialStore {
    public static func parse(_ raw: Data) -> CodexCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let tokens = root.dict("tokens"),
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return CodexCredentials(accessToken: token, accountId: tokens["account_id"] as? String)
    }

    public static func load(codexHome: URL) -> CodexCredentials? {
        guard let raw = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")) else { return nil }
        return parse(raw)
    }
}

public struct CodexLimitFetcher: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    let client: HTTPClient
    let codexHome: URL

    public init(client: HTTPClient, codexHome: URL) {
        self.client = client
        self.codexHome = codexHome
    }

    public func fetch(now: Date = Date()) async throws -> LimitSnapshot {
        guard let credentials = CodexCredentialStore.load(codexHome: codexHome) else {
            throw LimitError.noCredentials(.codex)
        }
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "TokenBar",
        ]
        if let accountId = credentials.accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-Id"] = accountId
        }
        let result = try await client.get(url: Self.endpoint, headers: headers)
        try LimitError.check(result, provider: .codex)
        return try Self.parse(result.data, now: now)
    }

    public static func parse(_ body: Data, now: Date) throws -> LimitSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rateLimit = root.dict("rate_limit")
        else { throw LimitError.badResponse }
        var windows: [LimitWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = rateLimit.dict(key), let used = window.double("used_percent") else { continue }
            var resetsAt: Date?
            if let epoch = window.double("reset_at"), epoch > 0 {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = window.double("reset_after_seconds") {
                resetsAt = now.addingTimeInterval(after)
            }
            let label = Format.windowLabel(seconds: window.int("limit_window_seconds"))
            windows.append(LimitWindow(label: label, usedPercent: used, resetsAt: resetsAt))
        }
        guard !windows.isEmpty else { throw LimitError.badResponse }
        return LimitSnapshot(provider: .codex, windows: windows, plan: root["plan_type"] as? String, fetchedAt: now, source: .api)
    }
}

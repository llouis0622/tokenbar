import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT · Codex"
        }
    }
}

public struct LimitWindow: Codable, Equatable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum LimitSource: String, Codable, Sendable {
    case api
    case localLog
    case cache
}

public struct LimitSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    public var windows: [LimitWindow]
    public var plan: String?
    public var fetchedAt: Date
    public var source: LimitSource

    public init(provider: Provider, windows: [LimitWindow], plan: String?, fetchedAt: Date, source: LimitSource) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public var primary: LimitWindow? { windows.first }

    public func normalized(now: Date) -> LimitSnapshot {
        var copy = self
        copy.windows = windows.map { window in
            if let reset = window.resetsAt, reset <= now {
                return LimitWindow(label: window.label, usedPercent: 0, resetsAt: nil)
            }
            return window
        }
        return copy
    }
}

public struct LimitResult: Equatable, Sendable {
    public let snapshot: LimitSnapshot?
    public let error: String?

    public init(snapshot: LimitSnapshot?, error: String?) {
        self.snapshot = snapshot
        self.error = error
    }
}

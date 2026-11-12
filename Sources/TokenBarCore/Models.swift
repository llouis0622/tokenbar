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

public struct TokenUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

public enum Period: String, CaseIterable, Sendable {
    case today
    case week
    case month

    public var title: String {
        switch self {
        case .today: return "오늘"
        case .week: return "7일"
        case .month: return "30일"
        }
    }

    public var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: midnight) ?? midnight
    }
}

public struct CostSummary: Equatable, Sendable {
    public var tokens: Int
    public var cost: Double
    public var unpricedTokens: Int

    public init(tokens: Int = 0, cost: Double = 0, unpricedTokens: Int = 0) {
        self.tokens = tokens
        self.cost = cost
        self.unpricedTokens = unpricedTokens
    }
}

public struct CostReport: Equatable, Sendable {
    public var byPeriod: [Period: [Provider: CostSummary]]
    public var generatedAt: Date

    public init(byPeriod: [Period: [Provider: CostSummary]], generatedAt: Date) {
        self.byPeriod = byPeriod
        self.generatedAt = generatedAt
    }

    public func summary(_ period: Period, _ provider: Provider) -> CostSummary {
        byPeriod[period]?[provider] ?? CostSummary()
    }

    public func total(_ period: Period) -> CostSummary {
        var sum = CostSummary()
        for provider in Provider.allCases {
            let item = summary(period, provider)
            sum.tokens += item.tokens
            sum.cost += item.cost
            sum.unpricedTokens += item.unpricedTokens
        }
        return sum
    }
}

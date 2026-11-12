import Foundation

public struct UsageAggregate {
    let starts: [(period: Period, start: Date)]
    var totals: [Period: [Provider: [String: TokenUsage]]] = [:]

    public init(now: Date, calendar: Calendar = .current) {
        starts = Period.allCases.map { ($0, $0.start(now: now, calendar: calendar)) }
    }

    public mutating func add(provider: Provider, model: String, timestamp: Date, usage: TokenUsage) {
        for item in starts where timestamp >= item.start {
            var current = totals[item.period]?[provider]?[model] ?? TokenUsage()
            current.input += usage.input
            current.output += usage.output
            current.cacheWrite5m += usage.cacheWrite5m
            current.cacheWrite1h += usage.cacheWrite1h
            current.cacheRead += usage.cacheRead
            totals[item.period, default: [:]][provider, default: [:]][model] = current
        }
    }
}

public enum CostCalculator {
    public static func report(aggregate: UsageAggregate, prices: PriceTable, now: Date) -> CostReport {
        var byPeriod: [Period: [Provider: CostSummary]] = [:]
        for (period, providers) in aggregate.totals {
            for (provider, models) in providers {
                var summary = CostSummary()
                for (model, usage) in models {
                    summary.tokens += usage.total
                    if let price = prices.price(for: model) {
                        summary.cost += price.cost(usage)
                    } else {
                        summary.unpricedTokens += usage.total
                    }
                }
                byPeriod[period, default: [:]][provider] = summary
            }
        }
        return CostReport(byPeriod: byPeriod, generatedAt: now)
    }
}

public actor UsageEngine {
    private let claude: ClaudeLimitFetcher
    private let codex: CodexLimitFetcher
    private let claudeLogs: ClaudeLogScanner
    private let codexLogs: CodexLogScanner
    private let prices: PriceStore
    private let limitsFile: URL
    private let home: URL
    private var claudeCredentials: ClaudeCredentials?
    private var lastGood: [Provider: LimitSnapshot]
    private var lastError: [Provider: String] = [:]
    private var nextAllowed: [Provider: Date] = [:]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDir: URL? = nil,
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        let support = supportDir ?? home.appendingPathComponent("Library/Application Support/TokenBar")
        SecureFile.prepareDirectory(support)
        let codexHome = CodexPaths.home(userHome: home)
        self.home = home
        self.claude = ClaudeLimitFetcher(client: client)
        self.codex = CodexLimitFetcher(client: client, codexHome: codexHome)
        self.claudeLogs = ClaudeLogScanner(home: home)
        self.codexLogs = CodexLogScanner(codexHome: codexHome)
        self.prices = PriceStore(supportDir: support, client: client)
        self.limitsFile = support.appendingPathComponent("limits.json")
        var restored: [Provider: LimitSnapshot] = [:]
        if let raw = try? Data(contentsOf: support.appendingPathComponent("limits.json")),
           let saved = try? JSONDecoder().decode([LimitSnapshot].self, from: raw) {
            for snapshot in saved {
                restored[snapshot.provider] = snapshot
            }
        }
        self.lastGood = restored
    }

    public func limits(now: Date = Date()) async -> [Provider: LimitResult] {
        var results: [Provider: LimitResult] = [:]
        for provider in Provider.allCases {
            results[provider] = await limit(for: provider, now: now)
        }
        return results
    }

    private func currentClaudeCredentials(now: Date) throws -> ClaudeCredentials {
        if let cached = claudeCredentials, let expiresAt = cached.expiresAt, expiresAt > now.addingTimeInterval(60) {
            return cached
        }
        claudeCredentials = nil
        guard let loaded = ClaudeCredentialStore.load(home: home) else {
            throw LimitError.noCredentials(.claude)
        }
        if let expiresAt = loaded.expiresAt, expiresAt <= now {
            throw LimitError.tokenExpired(.claude)
        }
        claudeCredentials = loaded
        return loaded
    }

    private func limit(for provider: Provider, now: Date) async -> LimitResult {
        if let next = nextAllowed[provider], now < next {
            return cached(provider, now: now)
        }
        do {
            let snapshot: LimitSnapshot
            switch provider {
            case .claude: snapshot = try await claude.fetch(using: currentClaudeCredentials(now: now), now: now)
            case .codex: snapshot = try await codex.fetch(now: now)
            }
            lastGood[provider] = snapshot
            lastError[provider] = nil
            nextAllowed[provider] = now.addingTimeInterval(60)
            persist()
            return LimitResult(snapshot: snapshot, error: nil)
        } catch {
            var wait: TimeInterval = 120
            if let known = error as? LimitError {
                lastError[provider] = known.message
                if case .rateLimited(let retryAfter) = known {
                    wait = min(max(retryAfter ?? 0, 300), 3_600)
                }
                if case .unauthorized(.claude) = known {
                    claudeCredentials = nil
                }
            } else {
                lastError[provider] = "네트워크 연결을 확인하세요."
            }
            nextAllowed[provider] = now.addingTimeInterval(wait)
            if provider == .codex, let local = codexLogs.latestRateLimits(now: now) {
                if lastGood[.codex] == nil || local.fetchedAt > lastGood[.codex]!.fetchedAt {
                    lastGood[.codex] = local
                    persist()
                }
            }
            return cached(provider, now: now)
        }
    }

    private func cached(_ provider: Provider, now: Date) -> LimitResult {
        guard var snapshot = lastGood[provider] else {
            return LimitResult(snapshot: nil, error: lastError[provider])
        }
        if lastError[provider] != nil, snapshot.source == .api {
            snapshot.source = .cache
        }
        return LimitResult(snapshot: snapshot.normalized(now: now), error: lastError[provider])
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(Array(lastGood.values)) {
            SecureFile.write(encoded, to: limitsFile)
        }
    }

    public func costs(now: Date = Date()) async -> CostReport {
        let cutoff = Period.month.start(now: now)
        var aggregate = UsageAggregate(now: now)
        claudeLogs.collect(since: cutoff, into: &aggregate)
        codexLogs.collect(since: cutoff, into: &aggregate)
        let table = await prices.table(now: now)
        return CostCalculator.report(aggregate: aggregate, prices: table, now: now)
    }
}

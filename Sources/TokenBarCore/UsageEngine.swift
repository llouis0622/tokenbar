import Foundation

public enum CostCalculator {
    public static func report(entries: [UsageEntry], prices: PriceTable, now: Date, calendar: Calendar = .current) -> CostReport {
        var byPeriod: [Period: [Provider: CostSummary]] = [:]
        var memo: [String: ModelPrice?] = [:]
        let starts = Period.allCases.map { ($0, $0.start(now: now, calendar: calendar)) }
        for entry in entries {
            let price: ModelPrice?
            if let known = memo[entry.model] {
                price = known
            } else {
                price = prices.price(for: entry.model)
                memo.updateValue(price, forKey: entry.model)
            }
            for (period, start) in starts where entry.timestamp >= start {
                var summary = byPeriod[period]?[entry.provider] ?? CostSummary()
                summary.tokens += entry.usage.total
                if let price {
                    summary.cost += price.cost(entry.usage)
                } else {
                    summary.unpricedTokens += entry.usage.total
                }
                byPeriod[period, default: [:]][entry.provider] = summary
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
    private var lastGood: [Provider: LimitSnapshot]
    private var lastError: [Provider: String] = [:]
    private var nextAllowed: [Provider: Date] = [:]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDir: URL? = nil,
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        let support = supportDir ?? home.appendingPathComponent("Library/Application Support/TokenBar")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let codexHome = CodexPaths.home(userHome: home)
        self.claude = ClaudeLimitFetcher(client: client, home: home)
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

    private func limit(for provider: Provider, now: Date) async -> LimitResult {
        if let next = nextAllowed[provider], now < next {
            return cached(provider, now: now)
        }
        do {
            let snapshot: LimitSnapshot
            switch provider {
            case .claude: snapshot = try await claude.fetch(now: now)
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
                    wait = max(retryAfter ?? 0, 300)
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
            try? encoded.write(to: limitsFile, options: .atomic)
        }
    }

    public func costs(now: Date = Date()) async -> CostReport {
        let cutoff = Period.month.start(now: now)
        let entries = claudeLogs.entries(since: cutoff) + codexLogs.entries(since: cutoff)
        let table = await prices.table(now: now)
        return CostCalculator.report(entries: entries, prices: table, now: now)
    }
}

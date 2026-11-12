import Foundation

public struct ModelPrice: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m ?? input * 1.25
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.cacheRead = cacheRead ?? input * 0.1
    }

    public func cost(_ usage: TokenUsage) -> Double {
        let sum = Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheWrite5m) * cacheWrite5m
            + Double(usage.cacheWrite1h) * cacheWrite1h
            + Double(usage.cacheRead) * cacheRead
        return sum / 1_000_000
    }
}

public struct PriceTable: Equatable, Sendable {
    public static let families: [(match: String, price: ModelPrice)] = [
        ("fable", ModelPrice(input: 10, output: 50)),
        ("mythos", ModelPrice(input: 10, output: 50)),
        ("opus", ModelPrice(input: 5, output: 25)),
        ("sonnet", ModelPrice(input: 3, output: 15)),
        ("haiku", ModelPrice(input: 1, output: 5)),
        ("gpt-5", ModelPrice(input: 1.25, output: 10)),
        ("codex", ModelPrice(input: 1.25, output: 10)),
    ]

    public var exact: [String: ModelPrice]

    public init(exact: [String: ModelPrice] = [:]) {
        self.exact = exact
    }

    public func price(for model: String) -> ModelPrice? {
        var name = model.lowercased()
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
        }
        if let hit = exact[name] { return hit }
        let undated = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if let hit = exact[undated] { return hit }
        let prefixes = exact.keys.filter { name.hasPrefix($0) }
        if let longest = prefixes.max(by: { $0.count < $1.count }), let hit = exact[longest] {
            return hit
        }
        return Self.families.first { name.contains($0.match) }?.price
    }

    public static func fromLiteLLM(_ body: Data) -> [String: ModelPrice] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        var prices: [String: ModelPrice] = [:]
        for (key, value) in root {
            guard let item = value as? [String: Any],
                  let provider = item["litellm_provider"] as? String,
                  provider == "anthropic" || provider == "openai",
                  let input = item.double("input_cost_per_token"),
                  let output = item.double("output_cost_per_token")
            else { continue }
            let million = 1_000_000.0
            prices[key.lowercased()] = ModelPrice(
                input: input * million,
                output: output * million,
                cacheWrite5m: item.double("cache_creation_input_token_cost").map { $0 * million },
                cacheWrite1h: item.double("cache_creation_input_token_cost_above_1hr").map { $0 * million },
                cacheRead: item.double("cache_read_input_token_cost").map { $0 * million }
            )
        }
        return prices
    }
}

struct PriceCacheFile: Codable {
    var fetchedAt: Date
    var prices: [String: ModelPrice]
}

actor PriceStore {
    static let remote = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private let cacheFile: URL
    private let overrideFile: URL
    private let client: HTTPClient
    private var remotePrices: [String: ModelPrice] = [:]
    private var fetchedAt: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    init(supportDir: URL, client: HTTPClient) {
        self.cacheFile = supportDir.appendingPathComponent("prices.json")
        self.overrideFile = supportDir.appendingPathComponent("pricing.override.json")
        self.client = client
        if let raw = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(PriceCacheFile.self, from: raw) {
            remotePrices = cached.prices
            fetchedAt = cached.fetchedAt
        }
    }

    func table(now: Date) async -> PriceTable {
        if now.timeIntervalSince(fetchedAt) > 86_400, now.timeIntervalSince(lastAttempt) > 3_600 {
            lastAttempt = now
            if let result = try? await client.get(url: Self.remote, headers: [:]), result.status == 200 {
                let parsed = PriceTable.fromLiteLLM(result.data)
                if !parsed.isEmpty {
                    remotePrices = parsed
                    fetchedAt = now
                    if let encoded = try? JSONEncoder().encode(PriceCacheFile(fetchedAt: now, prices: parsed)) {
                        try? encoded.write(to: cacheFile, options: .atomic)
                    }
                }
            }
        }
        var merged = remotePrices
        if let raw = try? Data(contentsOf: overrideFile),
           let overrides = try? JSONDecoder().decode([String: ModelPrice].self, from: raw) {
            for (key, value) in overrides {
                merged[key.lowercased()] = value
            }
        }
        return PriceTable(exact: merged)
    }
}

import XCTest
@testable import TokenBarCore

final class TokenBarCoreTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ text: String, to relative: String) throws -> URL {
        let url = temp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testDateParsingHandlesFractionsAndOffsets() {
        XCTAssertEqual(DateParsing.parse("2026-11-12T00:00:00Z")?.timeIntervalSince1970, 1_794_441_600)
        XCTAssertEqual(DateParsing.parse("2026-11-12T00:00:00.943648+00:00")?.timeIntervalSince1970, 1_794_441_600)
        XCTAssertEqual(DateParsing.parse("2026-11-12T09:00:00.123+09:00")?.timeIntervalSince1970, 1_794_441_600)
        XCTAssertNil(DateParsing.parse("not a date"))
    }

    func testClaudeUsageParsing() throws {
        let body = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-11-12T05:00:00.123456+00:00"},
         "seven_day":{"utilization":17.5,"resets_at":"2026-11-15T00:00:00+00:00"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":3,"resets_at":null}}
        """
        let now = Date(timeIntervalSince1970: 1_794_441_600)
        let snapshot = try ClaudeLimitFetcher.parse(Data(body.utf8), plan: "max", now: now)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5시간", "주간", "주간 Sonnet"])
        XCTAssertEqual(snapshot.primary?.usedPercent, 42)
        XCTAssertEqual(snapshot.primary?.resetsAt, now.addingTimeInterval(5 * 3_600))
        XCTAssertNil(snapshot.windows[2].resetsAt)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertThrowsError(try ClaudeLimitFetcher.parse(Data("{}".utf8), plan: nil, now: now))
    }

    func testClaudeCredentialParsing() {
        let raw = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1794441600000,"subscriptionType":"pro"}}"#
        let parsed = ClaudeCredentialStore.parse(Data(raw.utf8))
        XCTAssertEqual(parsed?.accessToken, "tok")
        XCTAssertEqual(parsed?.expiresAt, Date(timeIntervalSince1970: 1_794_441_600))
        XCTAssertEqual(parsed?.plan, "pro")
        XCTAssertNil(ClaudeCredentialStore.parse(Data("{}".utf8)))
    }

    func testCodexUsageParsing() throws {
        let body = """
        {"plan_type":"plus","rate_limit":{"allowed":true,
          "primary_window":{"used_percent":18,"limit_window_seconds":18000,"reset_after_seconds":600,"reset_at":1794445200},
          "secondary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1794700800}}}
        """
        let now = Date(timeIntervalSince1970: 1_794_441_600)
        let snapshot = try CodexLimitFetcher.parse(Data(body.utf8), now: now)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5시간", "주간"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [18, 61])
        XCTAssertEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_794_445_200))
        XCTAssertEqual(snapshot.plan, "plus")
    }

    func testCodexCredentialParsing() {
        let raw = #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"abc","account_id":"acct"}}"#
        XCTAssertEqual(CodexCredentialStore.parse(Data(raw.utf8)), CodexCredentials(accessToken: "abc", accountId: "acct"))
        XCTAssertNil(CodexCredentialStore.parse(Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)))
    }

    func testNormalizedClearsExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = LimitSnapshot(
            provider: .claude,
            windows: [
                LimitWindow(label: "5시간", usedPercent: 80, resetsAt: now.addingTimeInterval(-10)),
                LimitWindow(label: "주간", usedPercent: 30, resetsAt: now.addingTimeInterval(100)),
            ],
            plan: nil,
            fetchedAt: now.addingTimeInterval(-3_600),
            source: .cache
        )
        let normalized = snapshot.normalized(now: now)
        XCTAssertEqual(normalized.windows[0].usedPercent, 0)
        XCTAssertEqual(normalized.windows[1].usedPercent, 30)
    }

    private func claudeLine(_ id: String, _ request: String, time: String, model: String = "claude-opus-4-5-20251101", output: Int, detail: Bool = true) -> String {
        let cache = detail ? #","cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}"# : ""
        return #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":10,"output_tokens":\#(output),"cache_creation_input_tokens":300,"cache_read_input_tokens":1000\#(cache)}}}"#
    }

    private func claudeTotals(_ scanner: ClaudeLogScanner, now: Date) -> [String: TokenUsage] {
        var aggregate = UsageAggregate(now: now)
        scanner.collect(since: Date(timeIntervalSince1970: 0), into: &aggregate)
        return aggregate.totals[.month]?[.claude] ?? [:]
    }

    func testClaudeLogScanDeduplicatesAcrossChunksAndFiles() throws {
        let now = DateParsing.parse("2026-11-12T03:00:00Z")!
        let first = [
            #"{"type":"user","timestamp":"2026-11-12T01:00:00.000Z","message":{"content":"usage"}}"#,
            claudeLine("msg_1", "req_1", time: "2026-11-12T01:00:01.000Z", output: 5),
            claudeLine("msg_1", "req_1", time: "2026-11-12T01:00:02.000Z", output: 50),
            #"{"type":"assistant","timestamp":"2026-11-12T01:00:03.000Z","message":{"id":"msg_s","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ].joined(separator: "\n") + "\n"
        let second = [
            claudeLine("msg_1", "req_1", time: "2026-11-12T01:00:02.000Z", output: 50, detail: false),
            #"{"type":"assistant","timestamp":"2026-11-12T02:00:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-haiku-4-5","usage":{"input_tokens":7,"output_tokens":3}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try write(first, to: ".claude/projects/a/one.jsonl")
        _ = try write(second, to: ".claude/projects/b/two.jsonl")
        let scanner = ClaudeLogScanner(home: temp)
        let totals = claudeTotals(scanner, now: now)
        XCTAssertEqual(totals.count, 2)
        let opus = try XCTUnwrap(totals["claude-opus-4-5-20251101"])
        XCTAssertEqual(opus.input, 10)
        XCTAssertEqual(opus.output, 50)
        XCTAssertEqual(opus.cacheWrite5m + opus.cacheWrite1h, 300)
        XCTAssertEqual(opus.cacheRead, 1000)
        XCTAssertEqual(totals["claude-haiku-4-5"], TokenUsage(input: 7, output: 3))
        XCTAssertEqual(scanner.cachedRecordCount, 3)
        XCTAssertEqual(claudeTotals(scanner, now: now), totals)
    }

    func testClaudeLogScanReadsOnlyAppendedLines() throws {
        let now = DateParsing.parse("2026-11-12T03:00:00Z")!
        let url = try write(claudeLine("msg_1", "req_1", time: "2026-11-12T01:00:01.000Z", output: 5) + "\n", to: ".claude/projects/a/one.jsonl")
        let scanner = ClaudeLogScanner(home: temp)
        XCTAssertEqual(claudeTotals(scanner, now: now)["claude-opus-4-5-20251101"]?.output, 5)

        let partial = claudeLine("msg_2", "req_2", time: "2026-11-12T01:10:00.000Z", output: 7)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.prefix(40).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(claudeTotals(scanner, now: now)["claude-opus-4-5-20251101"]?.output, 5)

        let rest = try FileHandle(forWritingTo: url)
        try rest.seekToEnd()
        try rest.write(contentsOf: Data((String(partial.dropFirst(40)) + "\n").utf8))
        try rest.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        XCTAssertEqual(claudeTotals(scanner, now: now)["claude-opus-4-5-20251101"]?.output, 12)
        XCTAssertEqual(scanner.cachedRecordCount, 2)
    }

    func testCodexLogScanUsesTotalsAndSkipsDuplicates() throws {
        let now = DateParsing.parse("2026-11-12T03:00:00Z")!
        let log = """
        {"timestamp":"2026-11-12T01:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-12T01:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}
        {"timestamp":"2026-11-12T01:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1794445200},"secondary":{"used_percent":40,"window_minutes":10080,"resets_in_seconds":3600}}}}
        {"timestamp":"2026-11-12T01:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}}}}
        {"timestamp":"2026-11-12T01:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":1400,"output_tokens":350},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":250}}}}

        """
        _ = try write(log, to: ".codex/sessions/2026/11/12/rollout.jsonl")
        let scanner = CodexLogScanner(codexHome: temp.appendingPathComponent(".codex"))
        var aggregate = UsageAggregate(now: now)
        scanner.collect(since: Date(timeIntervalSince1970: 0), into: &aggregate)
        XCTAssertEqual(aggregate.totals[.month]?[.codex], ["gpt-5-codex": TokenUsage(input: 1600, output: 350, cacheRead: 1400)])

        let limits = scanner.latestRateLimits(now: Date())
        XCTAssertEqual(limits?.source, .localLog)
        XCTAssertEqual(limits?.windows.map(\.label), ["5시간", "주간"])
        XCTAssertEqual(limits?.windows.first?.usedPercent, 12.5)
        XCTAssertEqual(limits?.windows.last?.resetsAt, DateParsing.parse("2026-11-12T02:00:02Z"))
    }

    func testNetworkAllowList() {
        XCTAssertTrue(URLSessionHTTPClient.isAllowed(URL(string: "https://api.anthropic.com/api/oauth/usage")!))
        XCTAssertTrue(URLSessionHTTPClient.isAllowed(URL(string: "https://chatgpt.com/backend-api/wham/usage")!))
        XCTAssertFalse(URLSessionHTTPClient.isAllowed(URL(string: "http://api.anthropic.com/api/oauth/usage")!))
        XCTAssertFalse(URLSessionHTTPClient.isAllowed(URL(string: "https://api.anthropic.com.evil.example/usage")!))
        XCTAssertFalse(URLSessionHTTPClient.isAllowed(URL(string: "https://user:pw@chatgpt.com/")!))
        XCTAssertFalse(URLSessionHTTPClient.isAllowed(URL(string: "https://example.com/")!))
    }

    func testUpdaterTrustsOnlyOwnRepository() async {
        XCTAssertTrue(Updater.isTrusted(remote: "https://github.com/llouis0622/tokenbar.git\n"))
        XCTAssertTrue(Updater.isTrusted(remote: "git@github.com:llouis0622/tokenbar.git"))
        XCTAssertTrue(Updater.isTrusted(remote: "https://github.com/LLouis0622/TokenBar/"))
        XCTAssertFalse(Updater.isTrusted(remote: "https://github.com/someone/tokenbar.git"))
        XCTAssertFalse(Updater.isTrusted(remote: "https://github.com/llouis0622/tokenbar.evil.example/x"))
        XCTAssertTrue(Updater.isCommit(String(repeating: "a1", count: 20)))
        XCTAssertFalse(Updater.isCommit("unknown"))
        XCTAssertFalse(Updater.isCommit("main; rm -rf ~"))

        let log = temp.appendingPathComponent("update.log")
        let missing = Updater(sourceDir: nil, installedCommit: nil, logFile: log)
        if case .unavailable = await missing.check() {} else { XCTFail("expected unavailable") }
        let foreign = Updater(sourceDir: temp.path, installedCommit: nil, logFile: log)
        if case .unavailable = await foreign.apply() {} else { XCTFail("expected unavailable") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testPricingLookupAndCost() {
        let table = PriceTable(exact: [
            "claude-opus-4-5": ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
            "gpt-5": ModelPrice(input: 1.25, output: 10, cacheRead: 0.125),
        ])
        XCTAssertEqual(table.price(for: "claude-opus-4-5-20251101")?.output, 25)
        XCTAssertEqual(table.price(for: "claude-opus-4-5[1m]")?.input, 5)
        XCTAssertEqual(table.price(for: "gpt-5-codex")?.cacheRead, 0.125)
        XCTAssertEqual(table.price(for: "claude-sonnet-9")?.input, 3)
        XCTAssertNil(table.price(for: "mystery-model"))

        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        XCTAssertEqual(table.price(for: "claude-opus-4-5")!.cost(usage), 46.75, accuracy: 0.0001)
    }

    func testLiteLLMParsing() {
        let body = """
        {"sample_spec":{"litellm_provider":"one of https://docs.litellm.ai"},
         "claude-test":{"litellm_provider":"anthropic","input_cost_per_token":0.000005,"output_cost_per_token":0.000025,"cache_read_input_token_cost":5e-07},
         "gemini-x":{"litellm_provider":"vertex_ai","input_cost_per_token":1e-06,"output_cost_per_token":1e-06}}
        """
        let prices = PriceTable.fromLiteLLM(Data(body.utf8))
        XCTAssertEqual(prices.count, 1)
        XCTAssertEqual(prices["claude-test"]?.input ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(prices["claude-test"]?.cacheRead ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(prices["claude-test"]?.cacheWrite5m ?? 0, 6.25, accuracy: 0.0001)
    }

    func testCostReportBucketsByPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = DateParsing.parse("2026-11-12T12:00:00+09:00")!
        let usage = TokenUsage(input: 1_000_000)
        let entries = [
            UsageEntry(provider: .claude, model: "claude-sonnet-4-5", timestamp: DateParsing.parse("2026-11-12T00:30:00+09:00")!, usage: usage),
            UsageEntry(provider: .claude, model: "claude-sonnet-4-5", timestamp: DateParsing.parse("2026-11-11T23:30:00+09:00")!, usage: usage),
            UsageEntry(provider: .codex, model: "gpt-5-codex", timestamp: DateParsing.parse("2026-10-20T10:00:00+09:00")!, usage: usage),
            UsageEntry(provider: .codex, model: "mystery-model", timestamp: DateParsing.parse("2026-11-12T10:00:00+09:00")!, usage: usage),
        ]
        let report = CostCalculator.report(entries: entries, prices: PriceTable(), now: now, calendar: calendar)
        XCTAssertEqual(report.summary(.today, .claude).cost, 3, accuracy: 0.0001)
        XCTAssertEqual(report.summary(.week, .claude).cost, 6, accuracy: 0.0001)
        XCTAssertEqual(report.summary(.week, .codex).cost, 0, accuracy: 0.0001)
        XCTAssertEqual(report.summary(.month, .codex).cost, 1.25, accuracy: 0.0001)
        XCTAssertEqual(report.summary(.today, .codex).unpricedTokens, 1_000_000)
        XCTAssertEqual(report.total(.month).tokens, 4_000_000)
    }

    func testFormatting() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(12_400_000), "12.4M")
        XCTAssertEqual(Format.usd(8.214), "$8.21")
        XCTAssertEqual(Format.usd(123.4), "$123")
        XCTAssertEqual(Format.percent(41.6), "42%")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 3_600 + 13 * 60), now: now), "2시간 13분 후 리셋")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3_600), now: now), "3일 4시간 후 리셋")
        XCTAssertEqual(Format.windowLabel(seconds: 18_000), "5시간")
        XCTAssertEqual(Format.windowLabel(seconds: 604_800), "주간")
    }

    func testRateFormatting() {
        XCTAssertEqual(Format.rate(0), "0.0K")
        XCTAssertEqual(Format.rate(9_000), "9.0K")
        XCTAssertEqual(Format.rate(123_400), "123K")
        XCTAssertEqual(Format.rate(1_240_000), "1.2M")
        XCTAssertEqual(Format.rate(2_500_000_000), "2.5G")
        XCTAssertEqual(Format.degrees(59.6), "60°")
    }

    func testSystemMonitorProducesPlausibleValues() async throws {
        let monitor = SystemMonitor()
        let first = await monitor.sample(includeTemperatures: true)
        XCTAssertNil(first.cpu)
        XCTAssertGreaterThan(first.memoryTotal, 0)
        XCTAssertGreaterThan(first.memoryUsed, 0)
        XCTAssertLessThanOrEqual(first.memoryUsed, first.memoryTotal)
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = await monitor.sample(includeTemperatures: false)
        let cpu = try XCTUnwrap(second.cpu)
        XCTAssertTrue((0...100).contains(cpu))
        let disk = try XCTUnwrap(second.diskPercent)
        XCTAssertTrue((0...100).contains(disk))
        XCTAssertGreaterThanOrEqual(second.upload, 0)
        XCTAssertGreaterThanOrEqual(second.download, 0)
    }
}

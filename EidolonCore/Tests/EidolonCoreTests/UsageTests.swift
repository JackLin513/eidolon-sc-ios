import Foundation
import XCTest
@testable import EidolonCore

/// The local service-call ledger and its pricing (spec #96).
final class UsageTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonUsage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make() throws -> Eidolon {
        try Eidolon(location: .init(root: root.appendingPathComponent("app")))
    }

    private func date(_ stamp: String) -> Date {
        Eidolon.parseTimestamp(stamp)!
    }

    private func call(
        _ service: ServiceName,
        provider: String,
        model: String,
        operation: ServiceOperation,
        unit: ServiceUnit,
        input: Int,
        output: Int? = nil,
        cachedInput: Int? = nil,
        estimated: Bool = false,
        at: String = "2026-11-04T03:00:00Z"
    ) -> ServiceCall {
        ServiceCall(
            at: date(at), service: service, provider: provider, model: model,
            operation: operation, unit: unit, input: input, output: output,
            cachedInput: cachedInput, estimated: estimated
        )
    }

    func testTheEstimatorCountsCJKByCharacterAndOtherTextByBytesOverFour() {
        XCTAssertEqual(UsageEstimate.tokens("你好世界"), 4)
        XCTAssertEqual(UsageEstimate.tokens("hello world"), 3) // 10 bytes / 4, rounded up
        XCTAssertEqual(UsageEstimate.tokens("你好 hello"), 2 + 2)
        XCTAssertEqual(UsageEstimate.tokens("   \n\t"), 0)
    }

    func testATextTurnIsPricedPerMillionTokensAndKept() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-v4-pro",
                 operation: .chatText, unit: .tokens, input: 1_000_000, output: 1_000_000)
        )

        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.calls, 1)
        XCTAssertEqual(stats.services.map(\.service), [.chat])
        let model = stats.services[0].models[0]
        XCTAssertEqual(model.price?.rate.currency, "CNY")
        XCTAssertEqual(model.amounts, [UsageMoney(currency: "CNY", amount: 36)])
        XCTAssertEqual(stats.amounts, [UsageMoney(currency: "CNY", amount: 36)])
        XCTAssertEqual(stats.unpricedCalls, 0)
        let keptCalls = try await eidolon.serviceCalls()
        XCTAssertEqual(keptCalls.count, 1)
    }

    func testCachedInputIsPricedApartAndTheRestAtTheInputPrice() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.openai.com", model: "gpt-6.1-sol",
                 operation: .chatText, unit: .tokens,
                 input: 1_000_000, output: 0, cachedInput: 400_000)
        )

        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        let model = stats.services[0].models[0]
        XCTAssertEqual(model.amounts, [UsageMoney(currency: "USD", amount: Decimal(string: "1.24")!)])
    }

    func testBytesSecondsAndImagesUseTheirOwnUnits() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.speech, provider: "api.fish.audio", model: "s2-pro",
                 operation: .speech, unit: .bytes, input: 1_000_000)
        )
        try await eidolon.recordServiceCall(
            call(.recognition, provider: "stt-rt.soniox.com", model: "stt-rt-v5",
                 operation: .recognition, unit: .seconds, input: 3_600)
        )
        try await eidolon.recordServiceCall(
            call(.image, provider: "image.novelai.net", model: "nai-diffusion-5-curated",
                 operation: .image, unit: .images, input: 2)
        )

        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        let amounts = Dictionary(uniqueKeysWithValues: stats.services.map {
            ($0.service, $0.amounts)
        })
        XCTAssertEqual(amounts[.speech], [UsageMoney(currency: "USD", amount: 15)])
        XCTAssertEqual(amounts[.recognition], [UsageMoney(currency: "USD", amount: Decimal(string: "0.12")!)])
        XCTAssertEqual(amounts[.image], [UsageMoney(currency: "USD", amount: Decimal(string: "0.072")!)])
    }

    func testBailianStreamingUsesItsTokenRateConvertedToSeconds() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.recognition, provider: "dashscope.aliyuncs.com",
                 model: "qwen-audio-3.1-asr-flash-streaming",
                 operation: .recognition, unit: .seconds, input: 3_600, estimated: true)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [UsageMoney(currency: "CNY", amount: Decimal(string: "0.54")!)])
        XCTAssertEqual(stats.services[0].models[0].price?.source, .preset)
        XCTAssertEqual(stats.services[0].estimatedCalls, 1)
    }

    func testBailian30UsesItsPerSecondPrice() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.recognition, provider: "dashscope.aliyuncs.com",
                 model: "qwen-audio-3.0-asr-flash-streaming",
                 operation: .recognition, unit: .seconds, input: 3_600)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [
            UsageMoney(currency: "CNY", amount: Decimal(string: "1.188")!),
        ])
        XCTAssertEqual(stats.services[0].estimatedCalls, 0)
    }

    func testDramaChargesPerCharacter() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.speech, provider: "api.fish.audio", model: "drama-3",
                 operation: .speech, unit: .characters, input: 1_000_000)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [UsageMoney(currency: "USD", amount: 50)])
    }

    func testAnUnknownPriceShowsTheUsageAndNoAmount() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.recognition, provider: "dashscope.aliyuncs.com", model: "paraformer-realtime-v2",
                 operation: .recognition, unit: .seconds, input: 120)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        let model = stats.services[0].models[0]
        XCTAssertNil(model.price)
        XCTAssertEqual(model.input, 120)
        XCTAssertEqual(model.amounts, [])
        XCTAssertEqual(stats.unpricedCalls, 1)
        XCTAssertEqual(stats.amounts, [])
    }

    func testABailianWorkspaceHostFindsItsRegionalPreset() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.judge, provider: "my-workspace.cn-beijing.maas.aliyuncs.com",
                 model: "decision-model-preview", operation: .judge,
                 unit: .tokens, input: 1_000_000)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.services[0].models[0].price?.source, .preset)
        XCTAssertEqual(stats.unpricedCalls, 0)
    }

    func testALocalHostCostsNothing() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "192.168.1.20", model: "qwen3-32b",
                 operation: .chatText, unit: .tokens, input: 10_000, output: 5_000)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.services[0].models[0].price?.source, .local)
        XCTAssertEqual(stats.amounts, [])
        XCTAssertEqual(stats.unpricedCalls, 0)
    }

    func testAnOverrideReplacesThePresetAndCanBeRestored() async throws {
        let eidolon = try make()
        let key = PriceKey(provider: "api.deepseek.com", model: "deepseek-v4-pro", unit: .tokens)
        try await eidolon.recordServiceCall(
            call(.chat, provider: key.provider, model: key.model,
                 operation: .chatText, unit: .tokens, input: 1_000_000, output: 0)
        )
        try await eidolon.setPriceOverride(
            key, input: 4, output: 0, cachedInput: nil, currency: "CNY",
            now: date("2026-11-04T00:00:00Z")
        )
        var stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [UsageMoney(currency: "CNY", amount: 4)])
        XCTAssertEqual(stats.services[0].models[0].price?.source, .override)

        try await eidolon.clearPriceOverride(key)
        stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [UsageMoney(currency: "CNY", amount: 9)])
        XCTAssertEqual(stats.services[0].models[0].price?.source, .preset)
    }

    func testCurrenciesAreKeptApart() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-v4-pro",
                 operation: .chatText, unit: .tokens, input: 1_000_000, output: 0)
        )
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.anthropic.com", model: "claude-sonnet-5-5",
                 operation: .chatText, unit: .tokens, input: 1_000_000, output: 0)
        )
        let stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.amounts, [
            UsageMoney(currency: "CNY", amount: 9),
            UsageMoney(currency: "USD", amount: 2),
        ])
    }

    func testTheRangeTakesWholeDaysInTheProducersZone() async throws {
        let eidolon = try make()
        // 2026-11-05 01:00 in Tokyo, still 2026-11-04 in UTC.
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-flash",
                 operation: .chatText, unit: .tokens, input: 10, at: "2026-11-04T16:00:00Z")
        )
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-flash",
                 operation: .chatText, unit: .tokens, input: 10, at: "2026-08-01T03:00:00Z")
        )
        let now = date("2026-11-05T03:00:00Z") // noon JST on the 5th
        let recent = try await eidolon.usageStats(range: .thirtyDays, now: now, timeZone: tokyo)
        XCTAssertEqual(recent.calls, 1)
        XCTAssertEqual(recent.days.count, 30)
        XCTAssertEqual(recent.days.last?.day, CalendarDay(year: 2026, month: 11, day: 5))
        XCTAssertEqual(recent.days.last?.calls, 1)

        let all = try await eidolon.usageStats(range: .all, now: now, timeZone: tokyo)
        XCTAssertEqual(all.calls, 2)
        XCTAssertEqual(all.days.first?.day, CalendarDay(year: 2026, month: 8, day: 1))
    }

    func testTheLedgerKnowsItHasRecordsOutsideTheRange() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-flash",
                 operation: .chatText, unit: .tokens, input: 10, at: "2026-08-01T03:00:00Z")
        )
        let now = date("2026-11-05T03:00:00Z")
        let recent = try await eidolon.usageStats(range: .thirtyDays, now: now, timeZone: tokyo)
        XCTAssertFalse(recent.hasAny)
        XCTAssertTrue(recent.hasRecords)
    }

    func testEstimatedCallsAreCountedAndClearingForgetsThem() async throws {
        let eidolon = try make()
        try await eidolon.recordServiceCall(
            call(.chat, provider: "api.deepseek.com", model: "deepseek-flash",
                 operation: .chatText, unit: .tokens, input: 100, estimated: true)
        )
        var stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.estimatedCalls, 1)
        XCTAssertEqual(stats.services[0].estimatedCalls, 1)
        XCTAssertEqual(stats.services[0].models[0].estimatedCalls, 1)

        try await eidolon.clearServiceCalls()
        stats = try await eidolon.usageStats(range: .all, now: date("2026-11-04T12:00:00Z"), timeZone: tokyo)
        XCTAssertEqual(stats.calls, 0)
        XCTAssertTrue(stats.days.isEmpty)
    }
}

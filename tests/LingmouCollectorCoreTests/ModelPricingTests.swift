import Foundation
import XCTest
@testable import LingmouCollectorCore

final class ModelPricingTests: XCTestCase {
    private let catalog = Data("""
        {"data":[
          {"id":"openai/gpt-6-sol","pricing":{
            "prompt":"0.000002","completion":"0.00001","input_cache_read":"0.0000002"}},
          {"id":"moonshotai/kimi-k3","pricing":{
            "prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003"}},
          {"id":"vendor/no-cache-price","pricing":{
            "prompt":"0.000001","completion":"0.000002"}},
          {"id":"openai/gpt-6-sol:batch","pricing":{
            "prompt":"0.000001","completion":"0.000005"}}
        ]}
        """.utf8)

    func testExactPricesAndUnpricedCoverage() throws {
        let prices = try XCTUnwrap(ModelPricing.parseCatalog(catalog))
        let estimate = ModelPricing.estimate(models: [
            "gpt-6-sol": UsageEntry(input: 1_000_000, output: 100_000, cache: 500_000),
            "k3": UsageEntry(input: 10, output: 0, cache: 0),
            "no-cache-price": UsageEntry(input: 10, output: 0, cache: 100),
            "未知模型": UsageEntry(input: 200, output: 0, cache: 0),
        ], prices: prices)
        XCTAssertEqual(estimate.byModelUsd["gpt-6-sol"] ?? 0, 3.1, accuracy: 0.0000001)
        XCTAssertEqual(estimate.byModelUsd["k3"] ?? 0, 0.00003, accuracy: 0.0000001)
        XCTAssertEqual(estimate.amountUsd, 3.10003, accuracy: 0.0000001)
        XCTAssertEqual(estimate.pricedTokens, 1_600_010)
        XCTAssertEqual(estimate.totalTokens, 1_600_320)
        XCTAssertEqual(estimate.unpricedModels, ["no-cache-price", "未知模型"])
        XCTAssertEqual(ModelPricing.catalogID(for: "gpt-6-sol", prices: prices),
                       "openai/gpt-6-sol")
        XCTAssertNil(ModelPricing.catalogID(for: "k3-agent", prices: prices))
    }

    func testCatalogCacheAvoidsRepeatedRequestsAndRetainsPricesOnFailure() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileSupport()
        var calls = 0
        let first = ModelPricing.collect(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_000),
            files: files, enabled: true, request: { calls += 1; return self.catalog })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first?.prices["openai/gpt-6-sol"]?.input, 0.000002)
        let cached = ModelPricing.collect(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_100),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cached?.fetchedAt, 100_000)
        let failed = ModelPricing.collect(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_000),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(failed?.fetchedAt, 100_000)
        let throttled = ModelPricing.collect(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_100),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(throttled)
        XCTAssertNil(ModelPricing.collect(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_200),
            files: files, enabled: false, request: { calls += 1; return self.catalog }))
        XCTAssertEqual(calls, 2)
    }

    func testMalformedAndAmbiguousPricesAreNotUsed() {
        let malformed = Data("""
            {"data":[
              {"id":"bad/negative","pricing":{"prompt":"-1","completion":"0.1"}},
              {"id":"bad/text","pricing":{"prompt":"NaN","completion":"0.1"}},
              {"id":"a/same","pricing":{"prompt":"0.1","completion":"0.2"}},
              {"id":"b/same","pricing":{"prompt":"0.1","completion":"0.2"}}
            ]}
            """.utf8)
        let prices = ModelPricing.parseCatalog(malformed) ?? [:]
        XCTAssertNil(prices["bad/negative"])
        XCTAssertNil(prices["bad/text"])
        XCTAssertNil(ModelPricing.catalogID(for: "same", prices: prices))
    }

    func testExchangeRateParsingAndIndependentFailureCache() throws {
        let valid = Data("""
            {"amount":1,"base":"USD","date":"2026-09-22","rates":{"CNY":6.7001}}
            """.utf8)
        XCTAssertEqual(ModelPricing.parseExchangeRate(valid)?.rate, 6.7001)
        XCTAssertEqual(ModelPricing.parseExchangeRate(valid)?.date, "2026-09-22")
        XCTAssertNil(ModelPricing.parseExchangeRate(Data("""
            {"base":"EUR","date":"2026-09-22","rates":{"CNY":6.7001}}
            """.utf8)))
        XCTAssertNil(ModelPricing.parseExchangeRate(Data("""
            {"base":"USD","date":"2026-09-22","rates":{"CNY":-1}}
            """.utf8)))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileSupport()
        var calls = 0
        let first = ModelPricing.collectExchangeRate(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_000),
            files: files, enabled: true, request: { calls += 1; return valid })
        XCTAssertEqual(first?.rateCnyPerUsd, 6.7001)
        XCTAssertEqual(calls, 1)
        let cached = ModelPricing.collectExchangeRate(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_100),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(cached?.sourceDate, "2026-09-22")
        XCTAssertEqual(calls, 1)
        let failed = ModelPricing.collectExchangeRate(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_000),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(failed?.rateCnyPerUsd, 6.7001)
        XCTAssertEqual(failed?.fetchedAt, 100_000)
        XCTAssertEqual(calls, 2)
        _ = ModelPricing.collectExchangeRate(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_100),
            files: files, enabled: true, request: { calls += 1; return valid })
        XCTAssertEqual(calls, 2)
        XCTAssertNil(ModelPricing.collectExchangeRate(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 200_000),
            files: files, enabled: false, request: { calls += 1; return valid }))
        XCTAssertEqual(calls, 2)
    }

    func testExchangeRateUnavailableDoesNotSuppressDollarEstimate() throws {
        let cache = ModelPriceCache(
            fetchedAt: 100, lastAttemptAt: 100,
            prices: try XCTUnwrap(ModelPricing.parseCatalog(catalog)))
        let usage = UsageData(
            date: "2026-09-23", tools: [:],
            total: UsageEntry(input: 100, output: 0, cache: 0),
            heatmap: nil, heatmax: nil,
            models: ["gpt-6-sol": UsageEntry(input: 100, output: 0, cache: 0)])
        let cost = try XCTUnwrap(ModelPricing.costData(
            local: usage, merged: nil, cache: cache, exchangeRate: nil))
        XCTAssertNil(cost.usdToCny)
        XCTAssertEqual(cost.local?.today.amountUsd ?? 0, 0.0002, accuracy: 0.0000001)
    }

    func testCostFieldsRoundTripThroughSharedSnakeCaseJSON() throws {
        let estimate = CostEstimate(
            amountUsd: 1.25, pricedTokens: 90, totalTokens: 100,
            byModelUsd: ["gpt-6-sol": 1.25], unpricedModels: ["未知模型"])
        let cost = CostData(
            source: "OpenRouter", priceUpdatedAt: 2_000_000_000,
            usdToCny: 6.7001, exchangeRateSource: "Frankfurter",
            exchangeRateDate: "2026-09-22", exchangeRateUpdatedAt: 2_000_000_001,
            local: CostPeriods(today: estimate, weekly: nil, monthly: nil), merged: nil)
        let status = StatusData(updatedAt: "12:00:00", tools: [], usage: nil, cost: cost)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try encoder.encode(status)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"amount_usd\""))
        XCTAssertTrue(text.contains("\"by_model_usd\""))
        XCTAssertTrue(text.contains("\"usd_to_cny\""))
        XCTAssertTrue(text.contains("\"exchange_rate_source\""))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(StatusData.self, from: encoded).cost, cost)
    }
}

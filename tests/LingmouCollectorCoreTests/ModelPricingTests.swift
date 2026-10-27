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

    func testModelsDevPricesKimiStandardAndHighspeed() throws {
        let data = Data("""
            {"moonshotai":{"models":{
              "kimi-k3.1-pro":{"id":"kimi-k3.1-pro","cost":{
                "input":2,"output":10,"cache_read":0.2,"cache_write":2}},
              "kimi-k3.1-pro-highspeed":{"id":"kimi-k3.1-pro-highspeed","cost":{
                "input":4,"output":20,"cache_read":0.2,"cache_write":4}}
            }}}
            """.utf8)
        let prices = try XCTUnwrap(ModelPricing.parseModelsDevCatalog(data))
        XCTAssertEqual(prices["moonshotai/kimi-k3.1-pro"]?.input, 0.000002)
        XCTAssertEqual(prices["moonshotai/kimi-k3.1-pro-highspeed"]?.output, 0.00002)
        XCTAssertEqual(prices["moonshotai/kimi-k3.1-pro-highspeed"]?.cacheRead ?? 0, 0.0000002,
                       accuracy: 0.000000000001)
        XCTAssertEqual(ModelPricing.catalogID(for: "k3.1-pro", prices: prices),
                       "moonshotai/kimi-k3.1-pro")
        XCTAssertEqual(ModelPricing.catalogID(for: "k3.1-pro-highspeed", prices: prices),
                       "moonshotai/kimi-k3.1-pro-highspeed")

        let estimate = ModelPricing.estimate(models: [
            "k3.1-pro": UsageEntry(input: 1_000_000, output: 100_000, cache: 500_000),
            "k3.1-pro-highspeed": UsageEntry(input: 1_000_000, output: 100_000, cache: 500_000),
        ], prices: prices)
        XCTAssertEqual(estimate.byModelUsd["k3.1-pro"] ?? 0, 3.1, accuracy: 0.0000001)
        XCTAssertEqual(estimate.byModelUsd["k3.1-pro-highspeed"] ?? 0, 6.1, accuracy: 0.0000001)
        XCTAssertEqual(estimate.amountUsd, 9.2, accuracy: 0.0000001)
        XCTAssertEqual(estimate.pricedTokens, 3_200_000)
        XCTAssertTrue(estimate.unpricedModels.isEmpty)
    }

    func testModelsDevCacheAndOpenRouterPrecedence() throws {
        let data = Data("""
            {"moonshotai":{"models":{
              "kimi-k3":{"id":"kimi-k3","cost":{"input":30,"output":150,"cache_read":3}},
              "kimi-k3.1-pro-highspeed":{"id":"kimi-k3.1-pro-highspeed","cost":{
                "input":4,"output":20,"cache_read":0.2}}
            }},"other":{"models":{
              "kimi-k3":{"id":"kimi-k3","cost":{"input":300,"output":1500,"cache_read":30}}
            }}}
            """.utf8)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileSupport()
        var calls = 0
        let first = ModelPricing.collectModelsDev(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_000),
            files: files, enabled: true, request: { calls += 1; return data })
        XCTAssertEqual(calls, 1)
        let cached = ModelPricing.collectModelsDev(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100_100),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cached?.fetchedAt, 100_000)
        let failed = ModelPricing.collectModelsDev(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_000),
            files: files, enabled: true, request: { calls += 1; return nil })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(failed?.fetchedAt, 100_000)
        XCTAssertNil(ModelPricing.collectModelsDev(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 190_200),
            files: files, enabled: false, request: { calls += 1; return data }))
        XCTAssertEqual(calls, 2)

        let openRouter = ModelPriceCache(
            fetchedAt: 100, lastAttemptAt: 100,
            prices: try XCTUnwrap(ModelPricing.parseCatalog(catalog)))
        let usage = UsageData(
            date: "2026-10-27", tools: [:],
            total: UsageEntry(input: 2_000_000, output: 100_000, cache: 500_000),
            heatmap: nil, heatmax: nil,
            models: [
                "kimi-k3": UsageEntry(input: 1_000_000, output: 0, cache: 0),
                "k3.1-pro-highspeed": UsageEntry(input: 1_000_000, output: 100_000, cache: 500_000),
            ])
        let cost = try XCTUnwrap(ModelPricing.costData(
            local: usage, merged: nil, cache: openRouter,
            modelsDevCache: first, exchangeRate: nil))
        XCTAssertEqual(cost.source, "OpenRouter + models.dev")
        XCTAssertEqual(cost.priceUpdatedAt, 100_000)
        XCTAssertEqual(cost.local?.today.byModelUsd["kimi-k3"] ?? 0, 3, accuracy: 0.0000001)
        XCTAssertEqual(cost.local?.today.byModelUsd["k3.1-pro-highspeed"] ?? 0, 6.1,
                       accuracy: 0.0000001)
        XCTAssertEqual(cost.local?.today.amountUsd ?? 0, 9.1, accuracy: 0.0000001)
        XCTAssertEqual(cost.local?.today.unpricedModels, [])
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

    func testDailyCostsUsePerModelPricesAndRetainUnpricedCoverage() throws {
        let prices = [
            "moonshotai/kimi-k3.1-pro": ModelUnitPrice(
                input: 0.000002, output: 0.00001, cacheRead: 0.0000002),
            "moonshotai/kimi-k3.1-pro-highspeed": ModelUnitPrice(
                input: 0.000004, output: 0.00002, cacheRead: 0.0000002),
        ]
        let usage = UsageData(
            date: "2026-10-27", tools: [:], total: UsageEntry(),
            heatmap: nil, heatmax: nil, models: [:],
            dailyModels: [
                "2026-10-26": ["k3.1-pro": UsageEntry(input: 1_000_000)],
                "2026-10-27": [
                    "k3.1-pro-highspeed": UsageEntry(input: 1_000_000),
                    "unknown": UsageEntry(input: 100),
                ],
            ])
        let periods = try XCTUnwrap(ModelPricing.periods(for: usage, prices: prices))
        XCTAssertEqual(periods.daily?.map(\.date), ["2026-10-26", "2026-10-27"])
        XCTAssertEqual(periods.daily?[0].estimate.amountUsd ?? 0, 2, accuracy: 0.0000001)
        XCTAssertEqual(periods.daily?[1].estimate.amountUsd ?? 0, 4, accuracy: 0.0000001)
        XCTAssertEqual(periods.daily?[1].estimate.unpricedModels, ["unknown"])
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

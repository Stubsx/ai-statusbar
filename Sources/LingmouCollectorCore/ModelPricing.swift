import Foundation

struct ModelUnitPrice: Codable, Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double?
}

struct ModelPriceCache: Codable {
    let fetchedAt: TimeInterval
    let lastAttemptAt: TimeInterval
    let prices: [String: ModelUnitPrice]
}

struct ExchangeRateCache: Codable {
    let fetchedAt: TimeInterval
    let lastAttemptAt: TimeInterval
    let rateCnyPerUsd: Double?
    let sourceDate: String?
}

/// OpenRouter publishes USD per token. Only exact catalog IDs are used; a
/// subscription or a different provider may charge a different actual amount.
enum ModelPricing {
    static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let exchangeURL = URL(string: "https://api.frankfurter.app/latest?from=USD&to=CNY")!
    static let refreshInterval: TimeInterval = 86_400
    static let retryInterval: TimeInterval = 3_600

    static func cachePath(home: String) -> String {
        (home as NSString).appendingPathComponent(".ai-statusbar/model-prices.json")
    }

    static func exchangeCachePath(home: String) -> String {
        (home as NSString).appendingPathComponent(".ai-statusbar/usd-cny-rate.json")
    }

    static func collectExchangeRate(
        environment: CollectorEnvironment,
        files: FileSupport,
        enabled: Bool,
        request: (() -> Data?)? = nil
    ) -> ExchangeRateCache? {
        guard enabled else { return nil }
        let path = exchangeCachePath(home: environment.homeDirectory)
        let cached = files.read(path).flatMap { try? JSONDecoder().decode(ExchangeRateCache.self, from: $0) }
        let now = environment.now
        if let cached, cached.rateCnyPerUsd != nil, now - cached.fetchedAt < refreshInterval {
            return cached
        }
        if let cached, now - cached.lastAttemptAt < retryInterval {
            return cached.rateCnyPerUsd == nil ? nil : cached
        }

        let data = request?() ?? (request == nil ? download(exchangeURL) : nil)
        if let data, let parsed = parseExchangeRate(data) {
            let fresh = ExchangeRateCache(
                fetchedAt: now, lastAttemptAt: now,
                rateCnyPerUsd: parsed.rate, sourceDate: parsed.date)
            save(fresh, to: path, files: files)
            return fresh
        }
        let failed = ExchangeRateCache(
            fetchedAt: cached?.fetchedAt ?? 0, lastAttemptAt: now,
            rateCnyPerUsd: cached?.rateCnyPerUsd, sourceDate: cached?.sourceDate)
        save(failed, to: path, files: files)
        return failed.rateCnyPerUsd == nil ? nil : failed
    }

    static func parseExchangeRate(_ data: Data) -> (rate: Double, date: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["base"] as? String == "USD",
              let date = root["date"] as? String,
              date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let rates = root["rates"] as? [String: Any],
              let rate = rates["CNY"] as? NSNumber,
              rate.doubleValue.isFinite, rate.doubleValue > 0 else { return nil }
        return (rate.doubleValue, date)
    }

    static func collect(
        environment: CollectorEnvironment,
        files: FileSupport,
        enabled: Bool,
        request: (() -> Data?)? = nil
    ) -> ModelPriceCache? {
        guard enabled else { return nil }
        let path = cachePath(home: environment.homeDirectory)
        let cached = files.read(path).flatMap { try? JSONDecoder().decode(ModelPriceCache.self, from: $0) }
        let now = environment.now
        if let cached, now - cached.fetchedAt < refreshInterval { return cached }
        if let cached, now - cached.lastAttemptAt < retryInterval {
            return cached.prices.isEmpty ? nil : cached
        }

        let data = request?() ?? (request == nil ? download(catalogURL) : nil)
        if let data, let prices = parseCatalog(data), !prices.isEmpty {
            let fresh = ModelPriceCache(fetchedAt: now, lastAttemptAt: now, prices: prices)
            save(fresh, to: path, files: files)
            return fresh
        }
        let failed = ModelPriceCache(
            fetchedAt: cached?.fetchedAt ?? 0, lastAttemptAt: now,
            prices: cached?.prices ?? [:])
        save(failed, to: path, files: files)
        return failed.prices.isEmpty ? nil : failed
    }

    static func parseCatalog(_ data: Data) -> [String: ModelUnitPrice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return nil }
        var prices: [String: ModelUnitPrice] = [:]
        for row in rows {
            guard let id = row["id"] as? String,
                  let pricing = row["pricing"] as? [String: Any],
                  let input = rate(pricing["prompt"]),
                  let output = rate(pricing["completion"]) else { continue }
            prices[id] = ModelUnitPrice(
                input: input, output: output,
                cacheRead: rate(pricing["input_cache_read"]))
        }
        return prices
    }

    private static func rate(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? String {
            number = Double(value)
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = nil
        }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = LockedBox<Data?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode,
               (200..<300).contains(code) {
                result.set(data)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 9) == .timedOut { task.cancel() }
        return result.get()
    }

    private static func save(_ cache: ModelPriceCache, to path: String, files: FileSupport) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? files.writePrivateData(data, to: path)
    }

    private static func save(_ cache: ExchangeRateCache, to path: String, files: FileSupport) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? files.writePrivateData(data, to: path)
    }

    static func catalogID(for model: String, prices: [String: ModelUnitPrice]) -> String? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "未知模型" else { return nil }
        let preferred: String?
        if key.hasPrefix("gpt-") {
            preferred = "openai/\(key)"
        } else if key.hasPrefix("glm-") {
            preferred = "z-ai/\(key)"
        } else if key.hasPrefix("deepseek-") {
            preferred = "deepseek/\(key)"
        } else if key == "k3" {
            preferred = "moonshotai/kimi-k3"
        } else {
            preferred = nil
        }
        if let preferred, prices[preferred] != nil { return preferred }
        let exactSuffix = prices.keys.filter { $0.split(separator: "/").last.map(String.init) == key }
        return exactSuffix.count == 1 ? exactSuffix[0] : nil
    }

    static func estimate(
        models: [String: UsageEntry],
        prices: [String: ModelUnitPrice]
    ) -> CostEstimate {
        var amount = 0.0
        var pricedTokens = 0
        var totalTokens = 0
        var byModel: [String: Double] = [:]
        var unpriced: [String] = []
        for (model, entry) in models {
            let tokens = entry.input + entry.output + entry.cache
            totalTokens += tokens
            guard let id = catalogID(for: model, prices: prices),
                  let price = prices[id],
                  entry.cache == 0 || price.cacheRead != nil else {
                if tokens > 0 { unpriced.append(model) }
                continue
            }
            let cost = Double(entry.input) * price.input
                + Double(entry.output) * price.output
                + Double(entry.cache) * (price.cacheRead ?? 0)
            amount += cost
            pricedTokens += tokens
            byModel[model] = cost
        }
        return CostEstimate(
            amountUsd: amount, pricedTokens: pricedTokens, totalTokens: totalTokens,
            byModelUsd: byModel, unpricedModels: unpriced.sorted())
    }

    static func periods(for usage: UsageData?, prices: [String: ModelUnitPrice]) -> CostPeriods? {
        guard let usage, let today = usage.models else { return nil }
        return CostPeriods(
            today: estimate(models: today, prices: prices),
            weekly: usage.weekly?.models.map { estimate(models: $0, prices: prices) },
            monthly: usage.monthly?.models.map { estimate(models: $0, prices: prices) })
    }

    static func costData(
        local: UsageData?, merged: UsageData?, cache: ModelPriceCache?,
        exchangeRate: ExchangeRateCache?
    ) -> CostData? {
        guard let cache, !cache.prices.isEmpty else { return nil }
        return CostData(
            source: "OpenRouter", priceUpdatedAt: cache.fetchedAt,
            usdToCny: exchangeRate?.rateCnyPerUsd,
            exchangeRateSource: exchangeRate?.rateCnyPerUsd == nil ? nil : "Frankfurter",
            exchangeRateDate: exchangeRate?.sourceDate,
            exchangeRateUpdatedAt: exchangeRate?.rateCnyPerUsd == nil ? nil : exchangeRate?.fetchedAt,
            local: periods(for: local, prices: cache.prices),
            merged: periods(for: merged, prices: cache.prices))
    }
}

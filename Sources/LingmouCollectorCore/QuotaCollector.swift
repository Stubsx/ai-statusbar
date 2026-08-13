import Foundation

struct QuotaCollector {
    let environment: CollectorEnvironment
    let settings: CollectorSettings
    let files: FileSupport
    var requestOverride: ((URLRequest) -> JSONObject?)? = nil

    private struct CachedQuota {
        var codex: ToolQuota?
        var kimi: ToolQuota?
        var zcode: ToolQuota?
        var onlineQuotaEnabled: Bool
        var kimiMonthlyEnabled: Bool
        var kimiTokenMtime: TimeInterval
    }

    private struct MonthlyCache: Codable {
        var checkedAt: TimeInterval
        var tokenMtime: TimeInterval
        var quota: ToolQuota?
        var notice: String?
    }

    func collect() -> [String: ToolQuota?] {
        let cachePath = environment.path(".ai-statusbar", "quota-cache.json")
        let cached = readCache(cachePath)
        let tokenTime =
            settings.onlineQuota && settings.kimiMonthlyQuota ? kimiTokenModificationTime : 0
        let sameMode =
            cached?.onlineQuotaEnabled == settings.onlineQuota
            && cached?.kimiMonthlyEnabled == settings.kimiMonthlyQuota
        if let cached, sameMode,
            cached.kimiTokenMtime == tokenTime,
            environment.now - (files.modificationTime(cachePath) ?? 0) <= 300
        {
            return ["codex": cached.codex, "kimi": cached.kimi, "zcode": cached.zcode]
        }

        let old = cached
        var codex: ToolQuota? = settings.onlineQuota ? codexOnline() ?? codexLocal() : codexLocal()
        var kimi: ToolQuota? = settings.onlineQuota ? kimiQuota() : nil
        var zcode: ToolQuota? = settings.onlineQuota ? zcodeQuota() : nil
        if sameMode {
            if codex == nil { codex = old?.codex }
            if kimi == nil { kimi = old?.kimi }
            if zcode == nil { zcode = old?.zcode }
        }
        let value = CachedQuota(
            codex: codex,
            kimi: kimi,
            zcode: zcode,
            onlineQuotaEnabled: settings.onlineQuota,
            kimiMonthlyEnabled: settings.kimiMonthlyQuota,
            kimiTokenMtime: tokenTime
        )
        writeCache(value, path: cachePath)
        return ["codex": codex, "kimi": kimi, "zcode": zcode]
    }

    private func readCache(_ path: String) -> CachedQuota? {
        guard let object = files.read(path).flatMap(JSONValue.object) else { return nil }
        func decodeQuota(_ key: String) -> ToolQuota? {
            guard let value = object[key], !(value is NSNull),
                JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value)
            else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(ToolQuota.self, from: data)
        }
        return CachedQuota(
            codex: decodeQuota("codex"),
            kimi: decodeQuota("kimi"),
            zcode: decodeQuota("zcode"),
            onlineQuotaEnabled: JSONValue.bool(
                object["_online_quota_enabled"] ?? object["online_quota_enabled"]) ?? false,
            kimiMonthlyEnabled: JSONValue.bool(
                object["_kimi_monthly_enabled"] ?? object["kimi_monthly_enabled"]) ?? false,
            kimiTokenMtime: JSONValue.double(
                object["_kimi_token_mtime"] ?? object["kimi_token_mtime"])
                ?? 0
        )
    }

    private func writeCache(_ cache: CachedQuota, path: String) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        func object(_ quota: ToolQuota?) -> Any {
            guard let quota, let data = try? encoder.encode(quota),
                let value = try? JSONSerialization.jsonObject(with: data)
            else { return NSNull() }
            return value
        }
        try? files.writePrivateJSON(
            [
                "codex": object(cache.codex),
                "kimi": object(cache.kimi),
                "zcode": object(cache.zcode),
                "_online_quota_enabled": cache.onlineQuotaEnabled,
                "_kimi_monthly_enabled": cache.kimiMonthlyEnabled,
                "_kimi_token_mtime": cache.kimiTokenMtime,
            ], to: path)
    }

    func codexLocal() -> ToolQuota? {
        let root = environment.path(".codex", "sessions")
        var pools: [String: (TimeInterval, JSONObject)] = [:]
        for path in files.files(atDepth: 4, under: root, where: { $0.hasSuffix(".jsonl") }) {
            guard let modified = files.modificationTime(path),
                environment.now - modified < 14 * 86_400
            else { continue }
            for object in files.jsonLines(files.readTail(path)) {
                guard let payload = object["payload"] as? JSONObject,
                    JSONValue.string(payload["type"]) == "token_count",
                    let limits = payload["rate_limits"] as? JSONObject
                else { continue }
                let timestamp = DateSupport.timestamp(object["timestamp"]) ?? 0
                let id = JSONValue.string(limits["limit_id"]) ?? "codex"
                if pools[id].map({ timestamp > $0.0 }) ?? true { pools[id] = (timestamp, limits) }
            }
        }
        guard let found = pools["codex"] ?? pools.values.max(by: { $0.0 < $1.0 }) else {
            return nil
        }
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let value = found.1[key] as? JSONObject,
                let minutes = JSONValue.int(value["window_minutes"]), minutes > 0
            else { continue }
            windows.append(
                window(
                    minutes: minutes,
                    percent: JSONValue.double(value["used_percent"]) ?? 0,
                    resetsAt: JSONValue.int(value["resets_at"]) ?? 0
                ))
        }
        guard !windows.isEmpty else { return nil }
        return ToolQuota(
            plan: JSONValue.string(found.1["plan_type"]),
            windows: windows,
            updatedAt: Int(environment.now)
        )
    }

    private func codexOnline() -> ToolQuota? {
        guard
            let auth = files.read(environment.path(".codex", "auth.json")).flatMap(
                JSONValue.object),
            let tokens = auth["tokens"] as? JSONObject,
            let token = JSONValue.string(tokens["access_token"]),
            let account = JSONValue.string(tokens["account_id"]),
            let object = request(
                url: "https://chatgpt.com/backend-api/wham/usage",
                headers: ["Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account]
            ), let limits = object["rate_limit"] as? JSONObject
        else { return nil }
        var windows: [QuotaWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let value = limits[key] as? JSONObject,
                let seconds = JSONValue.int(value["limit_window_seconds"]), seconds > 0
            else { continue }
            windows.append(
                window(
                    minutes: seconds / 60,
                    percent: JSONValue.double(value["used_percent"]) ?? 0,
                    resetsAt: JSONValue.int(value["reset_at"]) ?? 0
                ))
        }
        guard !windows.isEmpty else { return nil }
        return ToolQuota(
            plan: JSONValue.string(object["plan_type"]), windows: windows,
            updatedAt: Int(environment.now)
        )
    }

    private func kimiQuota() -> ToolQuota? {
        let coding = kimiCodingQuota()
        guard settings.kimiMonthlyQuota else { return coding }
        let monthly = kimiMonthlyQuota()
        if var quota = monthly.0 {
            quota.plan = coding?.plan
            return quota
        }
        var result = coding ?? ToolQuota(plan: nil, windows: [], updatedAt: Int(environment.now))
        result.notice = monthly.1
        return result
    }

    private func kimiCodingQuota() -> ToolQuota? {
        let path = environment.path(".kimi-code", "credentials", "kimi-code.json")
        guard let credential = files.read(path).flatMap(JSONValue.object),
            let token = JSONValue.string(credential["access_token"]), !token.isEmpty
        else { return nil }
        var expiration = JSONValue.double(credential["expires_at"]) ?? 0
        if expiration > 1_000_000_000_000 { expiration /= 1_000 }
        guard environment.now < expiration - 30,
            let object = request(
                url: "https://api.kimi.com/coding/v1/usages",
                headers: ["Authorization": "Bearer \(token)"]
            )
        else { return nil }
        func make(_ source: JSONObject, minutes: Int) -> QuotaWindow? {
            let used = JSONValue.int(source["used"]) ?? 0
            let limit = JSONValue.int(source["limit"]) ?? 0
            guard limit > 0 else { return nil }
            return window(
                minutes: minutes,
                percent: 100 * Double(used) / Double(limit),
                resetsAt: Int(DateSupport.timestamp(source["resetTime"]) ?? 0)
            )
        }
        var windows: [QuotaWindow] = []
        if let usage = object["usage"] as? JSONObject, let value = make(usage, minutes: 10_080) {
            windows.append(value)
        }
        for item in object["limits"] as? [JSONObject] ?? [] {
            if let detail = item["detail"] as? JSONObject,
                let value = make(
                    detail,
                    minutes: JSONValue.int((item["window"] as? JSONObject)?["duration"]) ?? 0)
            {
                windows.append(value)
            }
        }
        guard !windows.isEmpty else { return nil }
        let plan = (((object["user"] as? JSONObject)?["membership"] as? JSONObject)?["level"])
            .flatMap(
                JSONValue.string)
        return ToolQuota(plan: plan, windows: windows, updatedAt: Int(environment.now))
    }

    private var kimiTokenPath: String {
        environment.path(
            "Library", "Application Support", "kimi-desktop", "bridge-store", "token-store.json")
    }

    private var kimiTokenModificationTime: TimeInterval {
        files.modificationTime(kimiTokenPath) ?? 0
    }

    private func kimiMonthlyQuota() -> (ToolQuota?, String?) {
        let cachePath = environment.path(".ai-statusbar", "kimi-monthly-cache.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let tokenTime = kimiTokenModificationTime
        if let cacheData = files.read(cachePath),
            let cache = try? decoder.decode(MonthlyCache.self, from: cacheData),
            environment.now - cache.checkedAt < 3_600, cache.tokenMtime == tokenTime
        {
            return (cache.quota, cache.notice)
        }
        let live = kimiMonthlyLive()
        let cache = MonthlyCache(
            checkedAt: environment.now, tokenMtime: tokenTime, quota: live.0, notice: live.1)
        if let data = try? encoder.encode(cache),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            try? files.writePrivateJSON(object, to: cachePath)
        }
        return live
    }

    private func kimiMonthlyLive() -> (ToolQuota?, String?) {
        guard FileManager.default.fileExists(atPath: kimiTokenPath) else {
            return (nil, "需要安装并登录 Kimi App，才能读取月度配额")
        }
        guard let store = files.read(kimiTokenPath).flatMap(JSONValue.object),
            let tokens = store["tokens"] as? JSONObject,
            let token = JSONValue.string(tokens["access_token"]), !token.isEmpty
        else {
            return (nil, "Kimi 登录已过期，请打开 Kimi App 重新登录")
        }
        let expiration = jwtExpiration(token)
        guard expiration == 0 || environment.now < expiration - 30 else {
            return (nil, "Kimi 登录已过期，请打开 Kimi App 重新登录")
        }
        guard
            let object = request(
                url:
                    "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats",
                method: "POST",
                headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
                body: Data("{}".utf8)
            ), let balance = object["subscriptionBalance"] as? JSONObject,
            let totalRatio = JSONValue.double(balance["amountUsedRatio"])
        else { return (nil, nil) }
        let total = max(0, totalRatio * 100)
        let code = min(total, max(0, JSONValue.double(balance["kimiCodeUsedRatio"]) ?? 0) * 100)
        let reset = Int(DateSupport.timestamp(balance["expireTime"]) ?? 0)
        guard reset > 0 else { return (nil, nil) }
        var windows = [
            QuotaWindow(
                kind: "month",
                label: "本月",
                usedPercent: total.roundedTenth,
                resetsAt: reset,
                components: [
                    QuotaComponent(
                        key: "kimi", label: "Kimi", usedPercent: max(0, total - code).roundedTenth),
                    QuotaComponent(key: "code", label: "Code", usedPercent: code.roundedTenth),
                ]
            )
        ]
        for (key, kind, label) in [
            ("ratelimitCode5h", "5h", "5小时"), ("ratelimitCode7d", "week", "7天"),
        ] {
            guard let item = object[key] as? JSONObject,
                JSONValue.bool(item["enabled"]) != false,
                let ratio = JSONValue.double(item["ratio"])
            else { continue }
            windows.append(
                QuotaWindow(
                    kind: kind,
                    label: label,
                    usedPercent: max(0, ratio * 100).roundedTenth,
                    resetsAt: Int(DateSupport.timestamp(item["resetTime"]) ?? 0)
                ))
        }
        return (ToolQuota(plan: nil, windows: windows, updatedAt: Int(environment.now)), nil)
    }

    private func zcodeQuota() -> ToolQuota? {
        let path = environment.path(".zcode", "v2", "model-providers.json")
        guard let data = files.read(path),
            let providers = try? JSONSerialization.jsonObject(with: data) as? [JSONObject]
        else { return nil }
        var credential: (String, String)?
        for (name, base) in [
            ("Bigmodel - Coding Plan", "https://open.bigmodel.cn"),
            ("Z.AI - Coding Plan", "https://api.z.ai"),
        ] {
            if let provider = providers.first(where: { JSONValue.string($0["name"]) == name }),
                let key = JSONValue.string(provider["apiKey"]), !key.isEmpty
            {
                credential = (key, base)
                break
            }
        }
        guard let credential,
            let object = request(
                url: credential.1 + "/api/monitor/usage/quota/limit",
                headers: ["Authorization": "Bearer \(credential.0)"]
            ), JSONValue.int(object["code"]) == 200,
            let dataObject = object["data"] as? JSONObject
        else { return nil }
        var windows: [QuotaWindow] = []
        for limit in dataObject["limits"] as? [JSONObject] ?? []
        where JSONValue.string(limit["type"]) == "TOKENS_LIMIT" {
            windows.append(
                QuotaWindow(
                    kind: "5h",
                    label: "\(JSONValue.int(limit["number"]) ?? 0)小时",
                    usedPercent: (JSONValue.double(limit["percentage"]) ?? 0).roundedTenth,
                    resetsAt: (JSONValue.int(limit["nextResetTime"]) ?? 0) / 1_000
                ))
        }
        guard !windows.isEmpty else { return nil }
        return ToolQuota(
            plan: JSONValue.string(dataObject["level"]), windows: windows,
            updatedAt: Int(environment.now)
        )
    }

    private func window(minutes: Int, percent: Double, resetsAt: Int) -> QuotaWindow {
        let kind: String
        let label: String
        if minutes == 300 {
            kind = "5h"
            label = "5小时"
        } else if abs(minutes - 10_080) <= 60 {
            kind = "week"
            label = "本周"
        } else {
            kind = "custom"
            label = "\(minutes / 60)小时"
        }
        return QuotaWindow(
            kind: kind, label: label, usedPercent: percent.roundedTenth, resetsAt: resetsAt)
    }

    private func jwtExpiration(_ token: String) -> TimeInterval {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return 0 }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(
                of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap(JSONValue.object).flatMap {
            JSONValue.double($0["exp"])
        } ?? 0
    }

    private func request(
        url: String, method: String = "GET", headers: [String: String], body: Data? = nil
    ) -> JSONObject? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let requestOverride { return requestOverride(request) }
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<JSONObject?>(nil)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let status = (response as? HTTPURLResponse)?.statusCode,
                (200..<300).contains(status),
                let data
            {
                result.set(JSONValue.object(from: data))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 9)
        return result.get()
    }
}

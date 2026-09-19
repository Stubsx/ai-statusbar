import Foundation

struct QuotaCollector {
    let environment: CollectorEnvironment
    let settings: CollectorSettings
    let files: FileSupport
    /// App 在线判定用于代续期门控（App 运行中它自己会续期，灵眸不插手）。
    var processes: ProcessSupport? = nil
    var requestOverride: ((URLRequest) -> JSONObject?)? = nil
    var kimiKeychainOverride: ((String, String) -> Data?)? = nil

    /// token-store 被 Kimi 3.2.4+ 整包加密（safeStorage）时读不到明文凭证。这属于
    /// 读取手段缺失而不是账号退出，不应清空面板：命中这些提示时沿用上次月度配额。
    static let kimiEncryptedNotice = "新版 Kimi 已加密本地凭证，月度额度暂不可读（可在设置开启解密）"
    static let kimiDecryptFailedNotice = "无法解密新版 Kimi 凭证（钥匙串未授权或格式变化），月度额度沿用上次结果"
    static let kimiStaleableNotices: Set<String> = [kimiEncryptedNotice, kimiDecryptFailedNotice]

    private struct CachedQuota {
        var codex: ToolQuota?
        var kimi: ToolQuota?
        var kimiWork: ToolQuota?
        var zcode: ToolQuota?
        var onlineQuotaEnabled: Bool
        var kimiQuotaSeparated: Bool
        var kimiCodingTokenMtime: TimeInterval
        var kimiTokenMtime: TimeInterval
        /// 写入缓存时的解密开关；与当前设置不一致（含旧缓存缺失该字段）则不走快路径，
        /// 避免开关刚开启后仍回放"未开启解密"提示。
        var kimiDecryptEnabled: Bool
    }

    private struct MonthlyCache: Codable {
        /// 缓存结构版本；旧版（无 schema，含“登录已过期”误报时代）直接作废重算。
        var schema: Int = 2
        var checkedAt: TimeInterval
        var tokenMtime: TimeInterval
        /// 写入缓存时的解密开关；开关变化后旧缓存（含 nil）立即失效，
        /// 否则最长 1 小时内仍回放“未开启解密”提示。
        var decryptEnabled: Bool?
        var quota: ToolQuota?
        var notice: String?
    }

    func collect() -> [String: ToolQuota?] {
        let cachePath = environment.path(".ai-statusbar", "quota-cache.json")
        let cached = readCache(cachePath)
        let codingTokenTime = settings.onlineQuota ? kimiCodingTokenModificationTime : 0
        let monthlyTokenTime = settings.onlineQuota ? kimiTokenModificationTime : 0
        let sameMode =
            cached?.onlineQuotaEnabled == settings.onlineQuota
            && (!settings.onlineQuota || cached?.kimiQuotaSeparated == true)
        if let cached, sameMode,
            cached.kimiCodingTokenMtime == codingTokenTime,
            cached.kimiTokenMtime == monthlyTokenTime,
            cached.kimiDecryptEnabled == settings.kimiTokenDecrypt,
            (files.modificationTime(cachePath) ?? 0) >= kimiAuthorizationModificationTime,
            environment.now - (files.modificationTime(cachePath) ?? 0) <= 300
        {
            return [
                "codex": cached.codex, "kimi": cached.kimi, "kimi-work": cached.kimiWork,
                "zcode": cached.zcode,
            ]
        }

        let old = cached
        var codex: ToolQuota? = settings.onlineQuota ? codexOnline() ?? codexLocal() : codexLocal()
        var kimi: ToolQuota? = settings.onlineQuota ? kimiCodingQuota(previous: old?.kimi) : nil
        var kimiWork: ToolQuota? =
            settings.onlineQuota ? kimiWorkQuota(previous: old?.kimiWork) : nil
        var zcode: ToolQuota? = settings.onlineQuota ? zcodeQuota() : nil
        if sameMode {
            if codex == nil { codex = old?.codex }
            if kimi == nil, kimiCodingCredentialExists, let previous = old?.kimi,
                !previous.windows.isEmpty
            {
                kimi = previous
            }
            if kimiWork == nil, kimiWorkInstalled { kimiWork = old?.kimiWork }
            if zcode == nil { zcode = old?.zcode }
        }
        // Kimi Code 徽标优先用订阅档位名（如 Allegro，随 Kimi Work 凭证获得并缓存于其 plan）；
        // 没有 Kimi Work 的机器取不到，回退 Coding API 的原始等级（如 LEVEL_ADVANCED）。
        if let title = kimiWork?.plan, !title.isEmpty, var quota = kimi {
            quota.plan = title
            kimi = quota
        }
        let value = CachedQuota(
            codex: codex,
            kimi: kimi,
            kimiWork: kimiWork,
            zcode: zcode,
            onlineQuotaEnabled: settings.onlineQuota,
            kimiQuotaSeparated: true,
            kimiCodingTokenMtime: codingTokenTime,
            kimiTokenMtime: monthlyTokenTime,
            kimiDecryptEnabled: settings.kimiTokenDecrypt
        )
        writeCache(value, path: cachePath)
        return ["codex": codex, "kimi": kimi, "kimi-work": kimiWork, "zcode": zcode]
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
            kimiWork: decodeQuota("kimi-work") ?? decodeQuota("kimi_work"),
            zcode: decodeQuota("zcode"),
            onlineQuotaEnabled: JSONValue.bool(
                object["_online_quota_enabled"] ?? object["online_quota_enabled"]) ?? false,
            kimiQuotaSeparated: JSONValue.bool(
                object["_kimi_quota_separated"] ?? object["kimi_quota_separated"]) ?? false,
            kimiCodingTokenMtime: JSONValue.double(
                object["_kimi_coding_token_mtime"] ?? object["kimi_coding_token_mtime"])
                ?? 0,
            kimiTokenMtime: JSONValue.double(
                object["_kimi_token_mtime"] ?? object["kimi_token_mtime"])
                ?? 0,
            kimiDecryptEnabled: JSONValue.bool(
                object["_kimi_token_decrypt"] ?? object["kimi_token_decrypt"]) ?? false
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
                "kimi-work": object(cache.kimiWork),
                "zcode": object(cache.zcode),
                "_online_quota_enabled": cache.onlineQuotaEnabled,
                "_kimi_quota_separated": cache.kimiQuotaSeparated,
                "_kimi_token_decrypt": cache.kimiDecryptEnabled,
                "_kimi_coding_token_mtime": cache.kimiCodingTokenMtime,
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
            updatedAt: Int(found.0)
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

    private func kimiCodingQuota(previous: ToolQuota?) -> ToolQuota? {
        guard kimiCodingCredentialExists else { return nil }
        let coding = kimiCodingQuota()
        if var quota = coding.quota {
            quota.notice = coding.notice
            return quota
        }
        if coding.notice == nil, let previous {
            let windows = previous.windows.filter { $0.kind != "month" }
            if !windows.isEmpty {
                return ToolQuota(
                    plan: previous.plan, windows: windows, updatedAt: previous.updatedAt,
                    notice: nil)
            }
        }
        guard let notice = coding.notice else { return nil }
        return ToolQuota(plan: nil, windows: [], updatedAt: Int(environment.now), notice: notice)
    }

    private func kimiCodingQuota() -> (quota: ToolQuota?, notice: String?) {
        let path = environment.path(".kimi-code", "credentials", "kimi-code.json")
        guard FileManager.default.fileExists(atPath: path) else {
            return (nil, nil)
        }
        guard let credential = files.read(path).flatMap(JSONValue.object),
            let token = JSONValue.string(credential["access_token"]), !token.isEmpty
        else { return (nil, "Kimi Code 尚未登录，请运行 kimi login") }
        var expiration = JSONValue.double(credential["expires_at"]) ?? 0
        if expiration > 1_000_000_000_000 { expiration /= 1_000 }
        guard expiration == 0 || environment.now < expiration - 30 else {
            // Kimi Code 的短期 access token 过期不代表账号退出；CLI 会在真正使用时
            // 通过 refresh token 自行续期。灵眸保持只读并沿用最近一次有效配额。
            return (nil, nil)
        }
        guard
            let object = request(
                url: "https://api.kimi.com/coding/v1/usages",
                headers: ["Authorization": "Bearer \(token)"]
            )
        else { return (nil, nil) }
        func make(_ source: JSONObject, minutes: Int, label: String? = nil) -> QuotaWindow? {
            let used = JSONValue.int(source["used"]) ?? 0
            let limit = JSONValue.int(source["limit"]) ?? 0
            guard limit > 0 else { return nil }
            let value = window(
                minutes: minutes,
                percent: 100 * Double(used) / Double(limit),
                resetsAt: Int(DateSupport.timestamp(source["resetTime"]) ?? 0)
            )
            guard let label else { return value }
            return QuotaWindow(
                kind: value.kind,
                label: label,
                usedPercent: value.usedPercent,
                resetsAt: value.resetsAt,
                windowMinutes: minutes
            )
        }
        var windows: [QuotaWindow] = []
        if let usage = object["usage"] as? JSONObject,
            let value = make(usage, minutes: 10_080, label: "7天")
        {
            windows.append(value)
        }
        for item in object["limits"] as? [JSONObject] ?? [] {
            let minutes = JSONValue.int((item["window"] as? JSONObject)?["duration"]) ?? 0
            if let detail = item["detail"] as? JSONObject,
                let value = make(
                    detail,
                    minutes: minutes,
                    label: abs(minutes - 10_080) <= 60 ? "7天" : nil)
            {
                if !windows.contains(where: { $0.kind == value.kind && $0.label == value.label }) {
                    windows.append(value)
                }
            }
        }
        guard !windows.isEmpty else { return (nil, nil) }
        let plan = (((object["user"] as? JSONObject)?["membership"] as? JSONObject)?["level"])
            .flatMap(
                JSONValue.string)
        return (
            ToolQuota(plan: plan, windows: windows, updatedAt: Int(environment.now)),
            nil
        )
    }

    private var kimiCodingCredentialExists: Bool {
        FileManager.default.fileExists(
            atPath: environment.path(".kimi-code", "credentials", "kimi-code.json"))
    }

    private var kimiCodingTokenModificationTime: TimeInterval {
        files.modificationTime(
            environment.path(".kimi-code", "credentials", "kimi-code.json")) ?? 0
    }

    private var kimiTokenPath: String {
        environment.path(
            "Library", "Application Support", "kimi-desktop", "bridge-store", "token-store.json")
    }

    /// 把 token-store 文件对象解析成可用形态：旧版明文直接返回；新版 safeStorage
    /// 密文按需解密。encryptedPayload 非 nil 表示原文件是加密库（回写需重新加密）。
    private func kimiPlainTokenStore(_ raw: JSONObject) -> (
        plain: JSONObject?, encryptedPayload: String?, notice: String?
    ) {
        if raw["tokens"] != nil { return (raw, nil, nil) }
        guard JSONValue.string(raw["encryption"]) != nil,
            let payload = JSONValue.string(raw["data"])
        else { return (nil, nil, nil) }
        guard settings.kimiTokenDecrypt else {
            return (nil, payload, Self.kimiEncryptedNotice)
        }
        guard let plain = KimiSafeStorage.decryptTokenStore(
            payload: payload, keyProvider: kimiStorageKeyProvider)
        else { return (nil, payload, Self.kimiDecryptFailedNotice) }
        return (plain, payload, nil)
    }

    private var kimiStorageKeyProvider: (String, String) -> Data? {
        let base = kimiKeychainOverride ?? KimiSafeStorage.readKeychainPassword
        return { service, account in
            base(service, account)
                ?? KimiSafeStorage.cachedPassword(homeDirectory: environment.homeDirectory)
        }
    }

    /// 取 token-store 里的 access_token/refresh_token。旧版是明文 JSON（tokens.access_token）；
    /// Kimi 3.2.4+ 整包 safeStorage 加密（encryption/data 字段），需在设置中开启
    /// 解密并用钥匙串口令解开，读不到时返回对应的降级提示。refreshable 表示凭证
    /// 带 refresh_token（App 持有它即可免登录自动续期，access_token 过期≠账号退出）。
    private func kimiStoredAccessToken(_ raw: JSONObject) -> (
        token: String?, refreshToken: String?, refreshable: Bool, notice: String?
    ) {
        let resolved = kimiPlainTokenStore(raw)
        guard let plain = resolved.plain,
            // 兼容 {"tokens":{"access_token":…}} 与解密后直接平铺两种形态。
            let tokens = (plain["tokens"] as? JSONObject) ?? (plain.isEmpty ? nil : plain),
            let token = JSONValue.string(tokens["access_token"]), !token.isEmpty
        else { return (nil, nil, false, resolved.notice) }
        let refresh = JSONValue.string(tokens["refresh_token"]) ?? ""
        return (token, refresh.isEmpty ? nil : refresh, !refresh.isEmpty, nil)
    }

    private var kimiTokenModificationTime: TimeInterval {
        files.modificationTime(kimiTokenPath) ?? 0
    }

    private var kimiAuthorizationModificationTime: TimeInterval {
        files.modificationTime(environment.path(".ai-statusbar", "kimi-keychain-authorized")) ?? 0
    }

    private var kimiWorkRoot: String {
        environment.path("Library", "Application Support", "kimi-desktop")
    }

    private var kimiWorkInstalled: Bool {
        FileManager.default.fileExists(atPath: kimiWorkRoot)
    }

    private func kimiWorkQuota(previous: ToolQuota?) -> ToolQuota? {
        guard kimiWorkInstalled else { return nil }
        let monthly = kimiMonthlyQuota()
        if let quota = monthly.0 { return quota }
        guard let notice = monthly.1 else { return nil }
        // 凭证加密读不到时保留上次窗口、只更新提示，避免误报“登录已过期”清空面板。
        if Self.kimiStaleableNotices.contains(notice), var kept = previous,
            !kept.windows.isEmpty
        {
            kept.notice = notice
            return kept
        }
        return ToolQuota(plan: nil, windows: [], updatedAt: Int(environment.now), notice: notice)
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
            cache.schema == 2,
            cache.checkedAt >= kimiAuthorizationModificationTime,
            environment.now - cache.checkedAt < 3_600, cache.tokenMtime == tokenTime,
            cache.decryptEnabled == settings.kimiTokenDecrypt
        {
            return (cache.quota, cache.notice)
        }
        let live = kimiMonthlyLive()
        let cache = MonthlyCache(
            checkedAt: environment.now, tokenMtime: tokenTime,
            decryptEnabled: settings.kimiTokenDecrypt, quota: live.0, notice: live.1)
        if let data = try? encoder.encode(cache),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            try? files.writePrivateJSON(object, to: cachePath)
        }
        return live
    }

    private func kimiMonthlyLive() -> (ToolQuota?, String?) {
        guard FileManager.default.fileExists(atPath: kimiTokenPath) else {
            return (nil, "Kimi Work 尚未登录，无法读取本月额度")
        }
        guard let store = files.read(kimiTokenPath).flatMap(JSONValue.object) else {
            return (nil, "Kimi 登录已过期，请打开 Kimi App 重新登录")
        }
        let stored = kimiStoredAccessToken(store)
        guard var token = stored.token, !token.isEmpty else {
            return (nil, stored.notice ?? "Kimi 登录已过期，请打开 Kimi App 重新登录")
        }
        let expiration = jwtExpiration(token)
        if !(expiration == 0 || environment.now < expiration - 30) {
            // access_token 只是短期快照（实测约 15 分钟），App 持 refresh_token 会在
            // 使用时自动续期并回写。开启“代续期”后，灵眸在 App 关闭期间也会用
            // refresh_token 换新并回写，随后立即用新 token 查询。
            if let renewed = renewExpiredKimiToken(raw: store, stored: stored) {
                token = renewed
            } else if stored.refreshable {
                // 未开启代续期（或本次未成功）：灵眸沿用最近一次有效配额，
                // 过期只说明快照陈旧，不代表账号退出。
                return (nil, nil)
            } else {
                return (nil, "Kimi 登录已过期，请打开 Kimi App 重新登录")
            }
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
        // 同一凭证顺带查订阅档位名（如 Allegro）放进 plan：Kimi Work 卡片直接显示，
        // collect() 再把它提升为 Kimi Code 徽标（无 Kimi Work 的机器回退 Coding 原始等级）。
        // 查询失败仅降级为无档位名，不影响月度额度。
        let planTitle = subscriptionTitle(token: token)
        // 月度订阅按对日续期（到期 9月6日则本周期自 8月6日起）。
        // 用 UTC 日历取上月同日，误差至多一天，仅供前端时间游标推算窗口起点。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let resetDate = Date(timeIntervalSince1970: TimeInterval(reset))
        let monthMinutes = calendar.date(byAdding: .month, value: -1, to: resetDate)
            .map { max(0, Int(resetDate.timeIntervalSince($0) / 60)) }
        let windows = [
            QuotaWindow(
                kind: "month",
                label: "本月",
                usedPercent: total.roundedTenth,
                resetsAt: reset,
                windowMinutes: (monthMinutes ?? 0) > 0 ? monthMinutes : nil,
                components: [
                    QuotaComponent(
                        key: "kimi", label: "Kimi", usedPercent: max(0, total - code).roundedTenth),
                    QuotaComponent(key: "code", label: "Code", usedPercent: code.roundedTenth),
                ]
            )
        ]
        return (ToolQuota(plan: planTitle, windows: windows, updatedAt: Int(environment.now)), nil)
    }

    // MARK: - Kimi 凭证代续期（默认关闭的显式选项）

    private struct KimiTokenRefreshState: Codable {
        var lastAttemptAt: TimeInterval?
        var lastSuccessAt: TimeInterval?
    }

    private var kimiTokenRefreshStatePath: String {
        environment.path(".ai-statusbar", "kimi-token-refresh.json")
    }

    /// App 关闭期间用 refresh_token 代续期：成功则把新凭证按原格式回写 token-store
    /// 并立即用于本次配额查询。Kimi 的刷新接口会轮换 refresh_token，成功后不回写
    /// 会让 App 里存的旧凭证失效，因此回写失败视为本次续期失败（原文件不动）。
    private func renewExpiredKimiToken(
        raw: JSONObject,
        stored: (token: String?, refreshToken: String?, refreshable: Bool, notice: String?)
    ) -> String? {
        guard settings.kimiTokenRefreshHours > 0,
            let refreshToken = stored.refreshToken, !refreshToken.isEmpty,
            kimiTokenRefreshAttemptAllowed()
        else { return nil }
        let resolved = kimiPlainTokenStore(raw)
        guard let plain = resolved.plain else { return nil }
        // 先确认能按原格式回写（加密口令可用）再动用 refresh_token：请求一旦成功，
        // 服务端已轮换，回写不了就只能眼睁睁让 App 侧凭证失效。
        if resolved.encryptedPayload != nil,
            KimiSafeStorage.encryptTokenStore(plain: plain, keyProvider: kimiStorageKeyProvider) == nil
        { return nil }
        recordKimiTokenRefreshAttempt()
        guard let response = request(
            url: "https://www.kimi.com/api/auth/token/refresh",
            headers: ["Authorization": "Bearer \(refreshToken)"]
        ), let pair = renewedTokenPair(response)
        else { return nil }
        guard
            writeRenewedKimiTokenStore(raw: raw, plain: plain, access: pair.access, refresh: pair.refresh)
        else { return nil }
        recordKimiTokenRefreshSuccess()
        return pair.access
    }

    /// 代续期节流与门控：Kimi App 未运行（运行中它自己会续期，并发回写也有风险）
    /// 且距上次尝试超过设定频率。
    private func kimiTokenRefreshAttemptAllowed() -> Bool {
        if let processes, processes.isAppRunning(executableName: "Kimi") { return false }
        let interval = TimeInterval(max(1, settings.kimiTokenRefreshHours)) * 3_600
        if let last = readKimiTokenRefreshState().lastAttemptAt,
            environment.now - last < interval
        { return false }
        return true
    }

    /// 响应里定位新凭证：兼容顶层与 data/tokens 嵌套、snake/camel 命名。
    /// 新 access_token 已过期视为异常响应，整体丢弃。
    private func renewedTokenPair(_ object: JSONObject) -> (access: String, refresh: String?)? {
        func pair(in value: Any, depth: Int) -> (String, String?)? {
            guard depth <= 2, let dict = value as? JSONObject else { return nil }
            let access = JSONValue.string(dict["access_token"]) ?? JSONValue.string(dict["accessToken"])
            if let access, !access.isEmpty {
                let refresh = JSONValue.string(dict["refresh_token"])
                    ?? JSONValue.string(dict["refreshToken"])
                return (access, (refresh?.isEmpty ?? true) ? nil : refresh)
            }
            for child in dict.values.sorted(by: { String(describing: $0) < String(describing: $1) }) {
                if let found = pair(in: child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let result = pair(in: object, depth: 0) else { return nil }
        let expiration = jwtExpiration(result.0)
        guard expiration == 0 || environment.now < expiration - 30 else { return nil }
        return (access: result.0, refresh: result.1)
    }

    /// 回写 token-store：原文件先备份到灵眸目录；加密库按原样重新加密，明文库按
    /// 明文回写；沿用原文件权限位，不改动 Kimi 目录本身的权限。
    private func writeRenewedKimiTokenStore(
        raw: JSONObject, plain: JSONObject, access: String, refresh: String?
    ) -> Bool {
        var updatedPlain = plain
        if var tokens = plain["tokens"] as? JSONObject {
            tokens["access_token"] = access
            if let refresh { tokens["refresh_token"] = refresh }
            updatedPlain["tokens"] = tokens
        } else {
            updatedPlain["access_token"] = access
            if let refresh { updatedPlain["refresh_token"] = refresh }
        }
        let backupPath = environment.path(".ai-statusbar", "kimi-token-store-backup.json")
        if let original = files.read(kimiTokenPath) {
            try? files.writePrivateData(original, to: backupPath)
        }
        let encryption = JSONValue.string(raw["encryption"])
        let body: String?
        if encryption != nil {
            guard let encrypted = KimiSafeStorage.encryptTokenStore(
                plain: updatedPlain, keyProvider: kimiStorageKeyProvider)
            else { return false }
            let wrapper: JSONObject = ["encryption": encryption ?? "safeStorage.v1", "data": encrypted]
            body = (try? JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            guard JSONSerialization.isValidJSONObject(updatedPlain) else { return false }
            body = (try? JSONSerialization.data(withJSONObject: updatedPlain, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let body else { return false }
        let attributes = try? files.manager.attributesOfItem(atPath: kimiTokenPath)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
        do {
            try Data(body.utf8).write(to: URL(fileURLWithPath: kimiTokenPath), options: .atomic)
            try files.manager.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: kimiTokenPath)
            return true
        } catch { return false }
    }

    private func readKimiTokenRefreshState() -> KimiTokenRefreshState {
        guard let data = files.read(kimiTokenRefreshStatePath),
            let state = try? JSONDecoder().decode(KimiTokenRefreshState.self, from: data)
        else { return KimiTokenRefreshState() }
        return state
    }

    private func writeKimiTokenRefreshState(_ state: KimiTokenRefreshState) {
        if let data = try? JSONEncoder().encode(state) {
            try? files.writePrivateData(data, to: kimiTokenRefreshStatePath)
        }
    }

    private func recordKimiTokenRefreshAttempt() {
        var state = readKimiTokenRefreshState()
        state.lastAttemptAt = environment.now
        writeKimiTokenRefreshState(state)
    }

    private func recordKimiTokenRefreshSuccess() {
        var state = readKimiTokenRefreshState()
        state.lastSuccessAt = environment.now
        writeKimiTokenRefreshState(state)
    }

    private func subscriptionTitle(token: String) -> String? {
        guard
            let object = request(
                url:
                    "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription",
                method: "POST",
                headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
                body: Data("{}".utf8)
            ), let subscription = object["subscription"] as? JSONObject,
            let goods = subscription["goods"] as? JSONObject
        else { return nil }
        return JSONValue.string(goods["title"])
    }

    private func zcodeQuota() -> ToolQuota? {
        guard let credential = zcodeCredential(),
            let object = request(
                url: credential.base + "/api/monitor/usage/quota/limit",
                headers: ["Authorization": "Bearer \(credential.key)"]
            ), JSONValue.int(object["code"]) == 200,
            let dataObject = object["data"] as? JSONObject
        else { return nil }
        var windows: [QuotaWindow] = []
        for limit in dataObject["limits"] as? [JSONObject] ?? []
        where JSONValue.string(limit["type"]) == "TOKENS_LIMIT" {
            let hours = JSONValue.int(limit["number"]) ?? 0
            windows.append(
                QuotaWindow(
                    kind: "5h",
                    label: "\(hours)小时",
                    usedPercent: (JSONValue.double(limit["percentage"]) ?? 0).roundedTenth,
                    resetsAt: (JSONValue.int(limit["nextResetTime"]) ?? 0) / 1_000,
                    windowMinutes: hours > 0 ? hours * 60 : nil
                ))
        }
        guard !windows.isEmpty else { return nil }
        return ToolQuota(
            plan: JSONValue.string(dataObject["level"]), windows: windows,
            updatedAt: Int(environment.now)
        )
    }

    /// 找 ZCode 带额度的 API 凭证。新版 ZCode 把提供商存在 config.json 的 provider
    /// 字典里（按 builtin id 标识，密钥在 options.apiKey，入口在 options.baseURL）；
    /// 旧版 model-providers.json 数组保留为回退。只认 open.bigmodel.cn / api.z.ai
    /// 两个配额接口域名，start-plan 的 zcode.z.ai 等其他入口直接跳过。
    private func zcodeCredential() -> (key: String, base: String)? {
        let configPath = environment.path(".zcode", "v2", "config.json")
        if let data = files.read(configPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
            let providers = object["provider"] as? JSONObject
        {
            func pick(enabledOnly: Bool) -> (String, String)? {
                for (id, raw) in providers {
                    guard id.hasSuffix("coding-plan"), let provider = raw as? JSONObject,
                        !enabledOnly || JSONValue.bool(provider["enabled"]) == true,
                        let options = provider["options"] as? JSONObject,
                        let key = JSONValue.string(options["apiKey"]), !key.isEmpty,
                        let baseURL = JSONValue.string(options["baseURL"]),
                        let base = zcodeQuotaBase(from: baseURL)
                    else { continue }
                    return (key, base)
                }
                return nil
            }
            if let credential = pick(enabledOnly: true) ?? pick(enabledOnly: false) {
                return credential
            }
        }
        let legacyPath = environment.path(".zcode", "v2", "model-providers.json")
        if let data = files.read(legacyPath),
            let providers = try? JSONSerialization.jsonObject(with: data) as? [JSONObject]
        {
            for (name, base) in [
                ("Bigmodel - Coding Plan", "https://open.bigmodel.cn"),
                ("Z.AI - Coding Plan", "https://api.z.ai"),
            ] {
                if let provider = providers.first(where: { JSONValue.string($0["name"]) == name }),
                    let key = JSONValue.string(provider["apiKey"]), !key.isEmpty
                {
                    return (key, base)
                }
            }
        }
        return nil
    }

    /// 提供商 baseURL（如 https://open.bigmodel.cn/api/anthropic）→ 配额接口域名
    private func zcodeQuotaBase(from baseURL: String) -> String? {
        if baseURL.contains("open.bigmodel.cn") { return "https://open.bigmodel.cn" }
        if baseURL.contains("api.z.ai") { return "https://api.z.ai" }
        return nil
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
            kind: kind, label: label, usedPercent: percent.roundedTenth, resetsAt: resetsAt,
            windowMinutes: minutes)
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

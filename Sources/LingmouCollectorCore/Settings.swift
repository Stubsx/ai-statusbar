import Foundation

public struct CollectorSettings: Sendable {
    public var defaultBusySeconds: Int
    public var perToolBusySeconds: [String: Int]
    public var offlineAfterSeconds: Int
    public var onlineQuota: Bool
    /// 解密新版 Kimi（3.2.4+）safeStorage 加密的 token-store 以读取月度额度。
    /// 需要访问钥匙串 "kimi-desktop Safe Storage"，默认关闭。
    public var kimiTokenDecrypt: Bool
    /// Kimi App 关闭期间用 refresh_token 代续期凭证（小时；0=关闭，默认关闭）。
    /// 成功后会把新凭证按原格式回写 token-store（先备份），仅当解密开启且 App 未运行。
    public var kimiTokenRefreshHours: Int
    /// 用量同步（多设备汇总）。默认关闭；目录为空时用 iCloud Drive 默认目录
    public var usageSyncEnabled: Bool
    public var usageSyncDir: String?
    /// Fetch public model prices. Off by default; no usage or account data is sent.
    public var priceEstimatesEnabled: Bool

    public init(
        defaultBusySeconds: Int = 300,
        perToolBusySeconds: [String: Int] = [:],
        offlineAfterSeconds: Int = 10_800,
        onlineQuota: Bool = true,
        kimiTokenDecrypt: Bool = false,
        kimiTokenRefreshHours: Int = 0,
        usageSyncEnabled: Bool = false,
        usageSyncDir: String? = nil,
        priceEstimatesEnabled: Bool = false
    ) {
        self.defaultBusySeconds = defaultBusySeconds
        self.perToolBusySeconds = perToolBusySeconds
        self.offlineAfterSeconds = offlineAfterSeconds
        self.onlineQuota = onlineQuota
        self.kimiTokenDecrypt = kimiTokenDecrypt
        self.kimiTokenRefreshHours = kimiTokenRefreshHours
        self.usageSyncEnabled = usageSyncEnabled
        self.usageSyncDir = usageSyncDir
        self.priceEstimatesEnabled = priceEstimatesEnabled
    }

    public func busySeconds(for tool: String) -> Int {
        perToolBusySeconds[tool] ?? defaultBusySeconds
    }

    static func load(path: String, files: FileSupport) -> CollectorSettings {
        guard let data = files.read(path), let object = JSONValue.object(from: data) else {
            return CollectorSettings()
        }
        let online = JSONValue.bool(object["online_quota"]) ?? true
        let perTool =
            (object["per_tool"] as? JSONObject)?.reduce(into: [String: Int]()) {
                if let value = JSONValue.int($1.value) { $0[$1.key] = value }
            } ?? [:]
        let sync = object["usage_sync"] as? JSONObject
        let syncDir = JSONValue.string(sync?["dir"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CollectorSettings(
            defaultBusySeconds: JSONValue.int(object["default_busy_sec"]) ?? 300,
            perToolBusySeconds: perTool,
            offlineAfterSeconds: JSONValue.int(object["offline_after_sec"]) ?? 10_800,
            onlineQuota: online,
            kimiTokenDecrypt: JSONValue.bool(object["kimi_token_decrypt"]) ?? false,
            kimiTokenRefreshHours: JSONValue.int(object["kimi_token_refresh_hours"]) ?? 0,
            usageSyncEnabled: JSONValue.bool(sync?["enabled"]) ?? false,
            usageSyncDir: syncDir.isEmpty ? nil : syncDir,
            priceEstimatesEnabled: JSONValue.bool(object["price_estimates_enabled"]) ?? false
        )
    }
}

public struct CollectorEnvironment: Sendable {
    public var homeDirectory: String
    public var now: TimeInterval

    public init(
        homeDirectory: String = NSHomeDirectory(),
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    func path(_ components: String...) -> String {
        components.reduce(homeDirectory) { ($0 as NSString).appendingPathComponent($1) }
    }
}

import Foundation

public struct CollectorSettings: Sendable {
    public var defaultBusySeconds: Int
    public var perToolBusySeconds: [String: Int]
    public var offlineAfterSeconds: Int
    public var onlineQuota: Bool

    public init(
        defaultBusySeconds: Int = 300,
        perToolBusySeconds: [String: Int] = [:],
        offlineAfterSeconds: Int = 10_800,
        onlineQuota: Bool = true
    ) {
        self.defaultBusySeconds = defaultBusySeconds
        self.perToolBusySeconds = perToolBusySeconds
        self.offlineAfterSeconds = offlineAfterSeconds
        self.onlineQuota = onlineQuota
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
        return CollectorSettings(
            defaultBusySeconds: JSONValue.int(object["default_busy_sec"]) ?? 300,
            perToolBusySeconds: perTool,
            offlineAfterSeconds: JSONValue.int(object["offline_after_sec"]) ?? 10_800,
            onlineQuota: online
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

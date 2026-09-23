import Foundation

/// Quota and historical usage never block task state. Timestamps retain their original
/// freshness, so a slow or failed refresh cannot make cached quota appear current.
public struct CollectorMetrics: Codable, Sendable {
    public let quotas: [String: ToolQuota]
    public let usage: UsageData?
    public let usageMerged: UsageData?
    public let sync: UsageSyncStatus?
    public let cost: CostData?
    public let collectedAt: TimeInterval

    public init(
        quotas: [String: ToolQuota], usage: UsageData?, usageMerged: UsageData?,
        sync: UsageSyncStatus?, cost: CostData? = nil, collectedAt: TimeInterval
    ) {
        self.quotas = quotas
        self.usage = usage
        self.usageMerged = usageMerged
        self.sync = sync
        self.cost = cost
        self.collectedAt = collectedAt
    }

    public static func path(home: String) -> String {
        (home as NSString).appendingPathComponent(".ai-statusbar/collector-metrics.json")
    }

    public static func load(home: String) -> CollectorMetrics? {
        guard let data = FileSupport().read(path(home: home)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(home: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileSupport().writePrivateData(data, to: Self.path(home: home))
    }
}

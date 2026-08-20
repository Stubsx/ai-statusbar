import Foundation

// 数据模型：对应 lingmou-collector --json 输出的 JSON 契约，各前端共用。

// MARK: - 数据模型（对应 lingmou-collector --json 的输出）

struct BusyItem: Codable, Hashable {
    let id: String
    let title: String
}

struct QuotaComponent: Codable, Hashable {
    let key: String
    let label: String
    let usedPercent: Double
}

struct QuotaWindow: Codable, Hashable {
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: Int
    let windowMinutes: Int?
    let components: [QuotaComponent]?
}

struct ToolQuota: Codable {
    let plan: String?
    let windows: [QuotaWindow]
    let updatedAt: Int
    let notice: String?
}

struct ToolStatus: Codable {
    let key: String
    let letter: String
    let name: String
    let state: String          // busy / idle / off
    let busyCount: Int
    let busyItems: [BusyItem]
    let detail: String
    let latestTitle: String?
    let latestAge: String?
    let quota: ToolQuota?
}

struct UsageEntry: Codable {
    let input: Int
    let output: Int
    let cache: Int
}

struct HeatDay: Codable {
    let date: String
    let total: Int
    let future: Bool
}

struct UsageRange: Codable {
    let tools: [String: UsageEntry]
    let total: UsageEntry
}

struct UsageData: Codable {
    let date: String
    let tools: [String: UsageEntry]
    let total: UsageEntry
    let heatmap: [HeatDay]?
    let heatmax: Int?
    let weekly: UsageRange?   // 近七日（含今日）；旧版 JSON 无此字段时为 nil
    let monthly: UsageRange?  // 近30日（含今日）
}

struct UsageSyncSource: Codable {
    let device: String
    let name: String
    let updatedAt: TimeInterval
    let days: Int
}

struct UsageSyncStatus: Codable {
    let enabled: Bool
    let dir: String?
    let device: String
    let name: String
    let sources: [UsageSyncSource]?
}

struct StatusData: Codable {
    let updatedAt: String
    let tools: [ToolStatus]
    let usage: UsageData?
    /// 合并同步目录所有设备后的用量/热力图；usage 恒为本机数据
    let usageMerged: UsageData?
    let sync: UsageSyncStatus?
}

extension Notification.Name {
    static let statusUpdated = Notification.Name("statusUpdated")
}

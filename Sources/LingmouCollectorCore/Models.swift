import Foundation

public struct BusyItem: Codable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct QuotaComponent: Codable, Hashable, Sendable {
    public let key: String
    public let label: String
    public let usedPercent: Double

    public init(key: String, label: String, usedPercent: Double) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
    }
}

public struct QuotaWindow: Codable, Hashable, Sendable {
    public let kind: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Int
    public let components: [QuotaComponent]?

    public init(
        kind: String,
        label: String,
        usedPercent: Double,
        resetsAt: Int,
        components: [QuotaComponent]? = nil
    ) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.components = components
    }
}

public struct ToolQuota: Codable, Hashable, Sendable {
    public var plan: String?
    public var windows: [QuotaWindow]
    public var updatedAt: Int
    public var notice: String?

    public init(plan: String?, windows: [QuotaWindow], updatedAt: Int, notice: String? = nil) {
        self.plan = plan
        self.windows = windows
        self.updatedAt = updatedAt
        self.notice = notice
    }
}

public struct ToolStatus: Codable, Hashable, Sendable {
    public let key: String
    public let letter: String
    public let name: String
    public let state: String
    public let busyCount: Int
    public let busyItems: [BusyItem]
    public let detail: String
    public let latestTitle: String?
    public let latestAge: String?
    public let quota: ToolQuota?

    public init(
        key: String,
        letter: String,
        name: String,
        state: String,
        busyItems: [BusyItem],
        detail: String,
        latestTitle: String?,
        latestAge: String?,
        quota: ToolQuota?
    ) {
        self.key = key
        self.letter = letter
        self.name = name
        self.state = state
        self.busyCount = busyItems.count
        self.busyItems = Array(busyItems.prefix(5))
        self.detail = detail
        self.latestTitle = latestTitle
        self.latestAge = latestAge
        self.quota = quota
    }
}

public struct UsageEntry: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cache: Int

    public init(input: Int = 0, output: Int = 0, cache: Int = 0) {
        self.input = input
        self.output = output
        self.cache = cache
    }

    mutating func add(_ other: UsageEntry) {
        input += other.input
        output += other.output
        cache += other.cache
    }
}

public struct HeatDay: Codable, Hashable, Sendable {
    public let date: String
    public let total: Int
    public let future: Bool

    public init(date: String, total: Int, future: Bool) {
        self.date = date
        self.total = total
        self.future = future
    }
}

public struct UsageData: Codable, Hashable, Sendable {
    public let date: String
    public let tools: [String: UsageEntry]
    public let total: UsageEntry
    public let heatmap: [HeatDay]?
    public let heatmax: Int?

    public init(
        date: String,
        tools: [String: UsageEntry],
        total: UsageEntry,
        heatmap: [HeatDay]?,
        heatmax: Int?
    ) {
        self.date = date
        self.tools = tools
        self.total = total
        self.heatmap = heatmap
        self.heatmax = heatmax
    }
}

/// 用量同步文件中的一行：某设备某天某工具的 token 计数。
public struct UsageSyncDay: Codable, Hashable, Sendable {
    public let date: String
    public let tool: String
    public let input: Int
    public let output: Int
    public let cache: Int

    public init(date: String, tool: String, input: Int, output: Int, cache: Int) {
        self.date = date
        self.tool = tool
        self.input = input
        self.output = output
        self.cache = cache
    }
}

/// 用量同步来源：一台已导出到同步目录的设备。
public struct UsageSyncSource: Codable, Hashable, Sendable {
    public let device: String
    public let name: String
    public let updatedAt: TimeInterval
    public let days: Int

    public init(device: String, name: String, updatedAt: TimeInterval, days: Int) {
        self.device = device
        self.name = name
        self.updatedAt = updatedAt
        self.days = days
    }
}

/// 用量同步状态：开关、目录与当前可见的设备来源。
public struct UsageSyncStatus: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let dir: String?
    public let device: String
    public let name: String
    public let sources: [UsageSyncSource]

    public init(
        enabled: Bool, dir: String?, device: String, name: String, sources: [UsageSyncSource]
    ) {
        self.enabled = enabled
        self.dir = dir
        self.device = device
        self.name = name
        self.sources = sources
    }
}

public struct StatusData: Codable, Hashable, Sendable {
    public let updatedAt: String
    public let tools: [ToolStatus]
    public let usage: UsageData?
    /// 合并同步目录中所有设备后的用量/热力图；usage 恒为本机数据，前端按需选择展示
    public let usageMerged: UsageData?
    public let sync: UsageSyncStatus?

    public init(
        updatedAt: String,
        tools: [ToolStatus],
        usage: UsageData?,
        usageMerged: UsageData? = nil,
        sync: UsageSyncStatus? = nil
    ) {
        self.updatedAt = updatedAt
        self.tools = tools
        self.usage = usage
        self.usageMerged = usageMerged
        self.sync = sync
    }
}

struct LatestItem: Sendable {
    let title: String
    let timestamp: TimeInterval
}

struct RawToolState: Sendable {
    var processOn = false
    var busy: [BusyItem] = []
    var latest: LatestItem?
    var activity: TimeInterval = 0
    var detail = "无进程"
}

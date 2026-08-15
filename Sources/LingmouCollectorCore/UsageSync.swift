import CryptoKit
import Foundation

/// 同步目录中的设备导出文件（usage-<deviceId>.json）。每个文件只有一个写入者（该设备），
/// 因此不存在并发冲突；读取端按设备去重后合并。
struct UsageSyncFile: Codable {
    var device: String
    var name: String
    var updatedAt: TimeInterval
    var daily: [UsageSyncDay]
}

/// 用量同步：通过用户自选的普通同步目录（默认 iCloud Drive）在多台设备间
/// 汇总 token 计数。每台设备只写自己的文件、只读别人的文件。
///
/// 边界（与 App 设置文案一致）：
/// - 只同步 日期×工具×计数，绝不含任务标题、会话内容或账号信息
/// - 配额是账号级数据，两台机器读到的是同一份，不参与合并（求和会翻倍）
/// - 官方 iCloud 容器/CloudKit 需要商店或描述文件签名，本项目走普通目录路径
enum UsageSync {
    static let filePrefix = "usage-"
    /// 导出保留天数：约一年，兼顾文件体积与热力图（70 天）之外的查看需求
    static let retentionDays = 365
    /// 数据未变化也要周期性刷新 updatedAt，供其他设备判断来源新鲜度
    static let heartbeatInterval: TimeInterval = 3600
    /// 数据变化后的写出节流，避免高频重写触发云盘持续上传
    static let writeThrottle: TimeInterval = 60

    struct DeviceIdentity {
        let id: String
        let name: String
    }

    /// iCloud Drive 的通用文档目录是普通文件系统路径，任何应用可读写，无需 entitlement
    static func defaultDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/灵眸")
    }

    static func exportPath(directory: String, device: String) -> String {
        (directory as NSString).appendingPathComponent("\(filePrefix)\(device).json")
    }

    /// 稳定设备标识：首次生成 UUID 存入 ~/.ai-statusbar/device-id。
    /// 不用主机名做键：改名/重装系统会让同一台机器被算两遍；名字仅作展示。
    static func deviceIdentity(home: String, files: FileSupport) -> DeviceIdentity {
        let path = (home as NSString).appendingPathComponent(".ai-statusbar/device-id")
        let existing = files.readText(path)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = existing.isEmpty ? UUID().uuidString : existing
        if existing.isEmpty {
            let directory = (path as NSString).deletingLastPathComponent
            try? files.ensurePrivateDirectory(directory)
            try? Data(id.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try? files.manager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let host = ProcessInfo.processInfo.hostName
        let name = host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
        return DeviceIdentity(id: id, name: name)
    }

    // MARK: 编码

    static func encode(_ file: UsageSyncFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) -> UsageSyncFile? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(UsageSyncFile.self, from: data)
    }

    // MARK: 导出

    /// 裁剪到保留窗口内并排序，保证相同数据导出的字节稳定（可哈希、可比较）
    static func exportFile(
        device: DeviceIdentity, daily: [UsageSyncDay], now: TimeInterval
    ) -> UsageSyncFile {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -retentionDays,
            to: Date(timeIntervalSince1970: now))
        let cutoffDay = cutoff.map { DateSupport.localDay($0.timeIntervalSince1970) } ?? ""
        return UsageSyncFile(
            device: device.id,
            name: device.name,
            updatedAt: now,
            daily: daily
                .filter { $0.date >= cutoffDay }
                .sorted { ($0.date, $0.tool) < ($1.date, $1.tool) })
    }

    /// 把本机 daily 导出到同步目录，返回 (是否写出, 最近一次写出时间)。
    /// 节流规则：数据变化且过节流窗口 → 写；未变化但距上次写出超过心跳 → 写。
    /// statePath 记录 last_write/last_hash，避免每次采集都触碰云盘文件。
    static func writeExport(
        directory: String,
        device: DeviceIdentity,
        daily: [UsageSyncDay],
        now: TimeInterval,
        statePath: String,
        files: FileSupport
    ) -> (written: Bool, lastWrite: TimeInterval) {
        let stable = exportFile(device: device, daily: daily, now: 0)
        guard let stableData = try? encode(stable) else { return (false, 0) }
        let hash = SHA256.hash(data: stableData)
            .map { String(format: "%02x", $0) }.joined()

        var lastWrite: TimeInterval = 0
        var lastHash = ""
        if let state = files.read(statePath), let object = JSONValue.object(from: state) {
            lastWrite = JSONValue.double(object["last_write"]) ?? 0
            lastHash = JSONValue.string(object["last_hash"]) ?? ""
        }
        let changed = hash != lastHash
        let dueHeartbeat = now - lastWrite >= heartbeatInterval
        let pastThrottle = now - lastWrite >= writeThrottle
        guard (changed && pastThrottle) || dueHeartbeat else { return (false, lastWrite) }

        let file = exportFile(device: device, daily: daily, now: now)
        guard let data = try? encode(file) else { return (false, lastWrite) }
        do {
            try files.ensurePrivateDirectory(directory)
            let path = exportPath(directory: directory, device: device.id)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try files.manager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            try? files.writePrivateJSON(
                ["last_write": now, "last_hash": hash], to: statePath)
            return (true, now)
        } catch {
            return (false, lastWrite)
        }
    }

    // MARK: 读取与合并

    /// 读取目录下所有设备文件：同设备多文件（iCloud 冲突副本等）取 updatedAt 最新者，
    /// 无法解析的文件跳过；设备标识以文件内容为准，不信任文件名。
    static func loadRemotes(directory: String, files: FileSupport) -> [UsageSyncFile] {
        var byDevice: [String: UsageSyncFile] = [:]
        for path in files.children(of: directory) {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix(filePrefix), name.hasSuffix(".json") else { continue }
            guard let file = files.read(path).flatMap(decode) else { continue }
            if let existing = byDevice[file.device], existing.updatedAt >= file.updatedAt {
                continue
            }
            byDevice[file.device] = file
        }
        return Array(byDevice.values)
    }

    /// 多组按天计数合并（date → tool → 求和）。token 由各机统计各自本地日志，求和即真实总量
    static func mergedDaily(_ groups: [[UsageSyncDay]]) -> [String: [String: UsageEntry]] {
        var out: [String: [String: UsageEntry]] = [:]
        for group in groups {
            for row in group {
                var entry = out[row.date]?[row.tool] ?? UsageEntry()
                entry.input += row.input
                entry.output += row.output
                entry.cache += row.cache
                out[row.date, default: [:]][row.tool] = entry
            }
        }
        return out
    }
}

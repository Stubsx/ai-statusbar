import Foundation
import XCTest

@testable import LingmouCollectorCore

final class UsageSyncTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func day(_ date: String, _ tool: String, input: Int = 1, output: Int = 2, cache: Int = 3)
        -> UsageSyncDay
    {
        UsageSyncDay(date: date, tool: tool, input: input, output: output, cache: cache)
    }

    private func syncFile(device: String, name: String, updatedAt: TimeInterval, daily: [UsageSyncDay])
        throws -> Data
    {
        try UsageSync.encode(
            UsageSyncFile(device: device, name: name, updatedAt: updatedAt, daily: daily))
    }

    func testMergedDailySumsAcrossDevices() {
        let merged = UsageSync.mergedDaily([
            [day("2026-08-15", "kimi", input: 10, output: 20, cache: 30)],
            [
                day("2026-08-15", "kimi", input: 1, output: 2, cache: 3),
                day("2026-08-15", "zcode", input: 5, output: 5, cache: 5),
                day("2026-08-14", "kimi", input: 7, output: 0, cache: 0),
            ],
        ])
        XCTAssertEqual(merged["2026-08-15"]?["kimi"]?.input, 11)
        XCTAssertEqual(merged["2026-08-15"]?["kimi"]?.output, 22)
        XCTAssertEqual(merged["2026-08-15"]?["kimi"]?.cache, 33)
        XCTAssertEqual(merged["2026-08-15"]?["zcode"]?.input, 5)
        XCTAssertEqual(merged["2026-08-14"]?["kimi"]?.input, 7)
        XCTAssertNil(merged["2026-08-13"])
    }

    func testLoadRemotesDedupesSameDeviceAndSkipsInvalid() throws {
        let directory = try temporaryDirectory()
        let files = FileSupport()
        try write(
            try syncFile(device: "A", name: "mac-a", updatedAt: 100, daily: [day("2026-08-15", "kimi")]),
            to: directory.appendingPathComponent("usage-A.json"))
        // iCloud 冲突副本：同设备不同文件名，内容里的设备标识才是键
        try write(
            try syncFile(device: "A", name: "mac-a", updatedAt: 200, daily: [day("2026-08-15", "kimi", input: 9)]),
            to: directory.appendingPathComponent("usage-A 2.json"))
        try write(
            try syncFile(device: "B", name: "mac-b", updatedAt: 150, daily: []),
            to: directory.appendingPathComponent("usage-B.json"))
        try write(Data("not json".utf8), to: directory.appendingPathComponent("usage-bad.json"))
        try write(Data("{}".utf8), to: directory.appendingPathComponent("notes.json"))

        let remotes = UsageSync.loadRemotes(directory: directory.path, files: files)
        XCTAssertEqual(remotes.count, 2)
        let deviceA = remotes.first { $0.device == "A" }
        XCTAssertEqual(deviceA?.updatedAt, 200)
        XCTAssertEqual(deviceA?.daily.first?.input, 9)
        XCTAssertNotNil(remotes.first { $0.device == "B" })
    }

    func testExportRetentionAndStableOrder() {
        let now = Date().timeIntervalSince1970
        let oldDate = UsageSyncDay.dateForTesting(
            secondsFromNow: -366 * 86_400, now: now)
        let edgeDate = UsageSyncDay.dateForTesting(
            secondsFromNow: -364 * 86_400, now: now)
        let device = UsageSync.DeviceIdentity(id: "A", name: "mac-a")
        let file = UsageSync.exportFile(
            device: device,
            daily: [
                day("2026-08-15", "zcode"), day(oldDate, "kimi"), day("2026-08-15", "codex"),
                day(edgeDate, "kimi"),
            ],
            now: now)
        XCTAssertEqual(file.daily.map(\.date), [edgeDate, "2026-08-15", "2026-08-15"])
        XCTAssertEqual(file.daily.map(\.tool), ["kimi", "codex", "zcode"])
        XCTAssertEqual(file.device, "A")
    }

    func testWriteExportThrottleAndHeartbeat() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("sync").path
        let statePath = root.appendingPathComponent("sync-state.json").path
        let files = FileSupport()
        let device = UsageSync.DeviceIdentity(id: "A", name: "mac-a")
        var daily = [day("2026-08-15", "kimi", input: 1)]

        // 首次：写出
        var result = UsageSync.writeExport(
            directory: directory, device: device, daily: daily, now: 1_000,
            statePath: statePath, files: files)
        XCTAssertTrue(result.written)
        XCTAssertEqual(result.lastWrite, 1_000)

        // 数据未变且在节流窗口内：跳过
        result = UsageSync.writeExport(
            directory: directory, device: device, daily: daily, now: 1_010,
            statePath: statePath, files: files)
        XCTAssertFalse(result.written)
        XCTAssertEqual(result.lastWrite, 1_000)

        // 数据变化但仍在节流窗口：延迟到窗口过后
        daily = [day("2026-08-15", "kimi", input: 2)]
        result = UsageSync.writeExport(
            directory: directory, device: device, daily: daily, now: 1_030,
            statePath: statePath, files: files)
        XCTAssertFalse(result.written)
        result = UsageSync.writeExport(
            directory: directory, device: device, daily: daily, now: 1_061,
            statePath: statePath, files: files)
        XCTAssertTrue(result.written)
        XCTAssertEqual(result.lastWrite, 1_061)

        // 数据未变超过心跳间隔：刷新 updatedAt
        result = UsageSync.writeExport(
            directory: directory, device: device, daily: daily,
            now: 1_061 + UsageSync.heartbeatInterval, statePath: statePath, files: files)
        XCTAssertTrue(result.written)

        // 写出的文件可被 loadRemotes 读回
        let remotes = UsageSync.loadRemotes(directory: directory, files: files)
        XCTAssertEqual(remotes.count, 1)
        XCTAssertEqual(remotes.first?.daily.first?.input, 2)
    }

    func testUsageDataBuildsTodayAndHeatmapFromMerged() {
        let now = Date().timeIntervalSince1970
        let today = DateSupport.localDay(now)
        let yesterday = DateSupport.localDay(now - 86_400)
        let usage = UsageCollector.usageData(
            from: UsageSync.mergedDaily([
                [
                    day(today, "kimi", input: 10, output: 20, cache: 30),
                    day(yesterday, "zcode", input: 100, output: 0, cache: 0),
                ],
                [day(today, "kimi", input: 1, output: 2, cache: 3)],
            ]),
            now: now)
        XCTAssertEqual(usage.tools["kimi"]?.input, 11)
        XCTAssertEqual(usage.total.input, 11)
        XCTAssertEqual(usage.total.output, 22)
        XCTAssertNotNil(usage.heatmap)
        XCTAssertEqual(usage.heatmap?.isEmpty, false)
        XCTAssertEqual((usage.heatmap?.count ?? 0) % 7, 0)
        XCTAssertEqual(
            usage.heatmap?.first { !$0.future && $0.date == yesterday }?.total, 100)
        XCTAssertEqual(usage.heatmax ?? 0, 100)
    }

    func testUsageDataBuildsWeeklyAndMonthlyRanges() {
        let now = Date().timeIntervalSince1970
        let calendar = Calendar.current
        let todayDate = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        func dayKey(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -offset, to: todayDate) ?? todayDate
            return DateSupport.localDay(date.timeIntervalSince1970)
        }
        let usage = UsageCollector.usageData(
            from: UsageSync.mergedDaily([[
                day(dayKey(0), "kimi", input: 10, output: 0, cache: 0),
                day(dayKey(6), "kimi", input: 100, output: 0, cache: 0),
                day(dayKey(7), "zcode", input: 1000, output: 0, cache: 0),
                day(dayKey(29), "claude", input: 5, output: 0, cache: 0),
                day(dayKey(30), "hermes", input: 7, output: 0, cache: 0),
            ]]),
            now: now)
        // 近七日窗口 = 今日 + 前 6 天：同工具跨天累加，第 7 天以前不参与
        XCTAssertEqual(usage.weekly?.tools["kimi"]?.input, 110)
        XCTAssertNil(usage.weekly?.tools["zcode"])
        XCTAssertEqual(usage.weekly?.total.input, 110)
        // 近30日窗口 = 今日 + 前 29 天：纳入第 7/29 天，排除第 30 天
        XCTAssertEqual(usage.monthly?.tools["kimi"]?.input, 110)
        XCTAssertEqual(usage.monthly?.tools["zcode"]?.input, 1000)
        XCTAssertEqual(usage.monthly?.tools["claude"]?.input, 5)
        XCTAssertNil(usage.monthly?.tools["hermes"])
        XCTAssertEqual(usage.monthly?.total.input, 1115)
    }

    func testStatusDataEncodesSyncFieldsWithSnakeCase() throws {
        let usage = UsageCollector.usageData(
            from: [:], now: Date().timeIntervalSince1970)
        let status = UsageSyncStatus(
            enabled: true, dir: "/tmp/lingmou-sync", device: "A", name: "mac-a",
            sources: [UsageSyncSource(device: "A", name: "mac-a", updatedAt: 1_000, days: 42)])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = try encoder.encode(
            StatusData(updatedAt: "12:00:00", tools: [], usage: usage, usageMerged: usage, sync: status))
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(text.contains("\"usage_merged\""))
        XCTAssertTrue(text.contains("\"sync\""))
        XCTAssertTrue(text.contains("\"updated_at\""))
        XCTAssertTrue(text.contains("\"sources\""))
    }

    func testSettingsLoadUsageSync() throws {
        let root = try temporaryDirectory()
        let settingsPath = root.appendingPathComponent("settings.json").path
        try write(
            Data(
                #"{"usage_sync":{"enabled":true,"dir":"/tmp/lingmou-sync"}}"#.utf8),
            to: URL(fileURLWithPath: settingsPath))
        let settings = CollectorSettings.load(path: settingsPath, files: FileSupport())
        XCTAssertTrue(settings.usageSyncEnabled)
        XCTAssertEqual(settings.usageSyncDir, "/tmp/lingmou-sync")

        // 空目录回落为 nil（用默认 iCloud 目录）
        try write(
            Data(#"{"usage_sync":{"enabled":true,"dir":"  "}}"#.utf8),
            to: URL(fileURLWithPath: settingsPath))
        XCTAssertNil(CollectorSettings.load(path: settingsPath, files: FileSupport()).usageSyncDir)
    }

    func testDeviceIdentityStableAcrossCalls() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = FileSupport()
        let first = UsageSync.deviceIdentity(home: root.path, files: files)
        let second = UsageSync.deviceIdentity(home: root.path, files: files)
        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
    }

    func testDefaultDirectoryPointsToICloudDrive() {
        let path = UsageSync.defaultDirectory(home: "/fake-home")
        XCTAssertEqual(
            path, "/fake-home/Library/Mobile Documents/com~apple~CloudDocs/灵眸")
    }
}

private extension UsageSyncDay {
    /// 仅供测试：相对 now 偏移秒数生成 yyyy-MM-dd
    static func dateForTesting(secondsFromNow: TimeInterval, now: TimeInterval) -> String {
        DateSupport.localDay(now + secondsFromNow)
    }
}

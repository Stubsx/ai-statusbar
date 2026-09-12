import Foundation
import XCTest
@testable import LingmouCollectorCore

final class EcosystemTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000
    private func event(_ id: Int) -> LocalEvent {
        LocalEvent(id: "event-\(id)", tool: "sample", session: "session", timestamp: now,
                   phase: "ended", evidence: "explicit", title: "私密测试标题")
    }

    func testEventPolicyRestartAndCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = LocalEventFeed(directory: directory)
        feed.configure(enabled: false, includeTitles: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feed.url.path))
        feed.configure(enabled: true, includeTitles: false)
        let baseline = try LocalEventFeed.read(directory: directory)
        feed.append([event(1), event(1)], includeTitles: false, now: now)
        let batch = try LocalEventFeed.read(directory: directory, after: baseline.cursor)
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertNil(batch.events[0].title)
        XCTAssertFalse(batch.gap)
        XCTAssertTrue(try LocalEventFeed.read(directory: directory, after: batch.cursor).events.isEmpty)
        let restart = LocalEventFeed(directory: directory)
        restart.configure(enabled: true, includeTitles: true)
        restart.append([event(1), event(2)], includeTitles: true, now: now)
        XCTAssertEqual(try LocalEventFeed.read(directory: directory).events.count, 2)
        XCTAssertEqual(try LocalEventFeed.read(directory: directory).events.last?.title, "私密测试标题")
        restart.configure(enabled: true, includeTitles: false)
        XCTAssertFalse(String(decoding: try Data(contentsOf: feed.url), as: UTF8.self).contains("私密测试标题"))
        restart.configure(enabled: false, includeTitles: false)
        restart.append([event(3)], includeTitles: true, now: now)
        let disabled = try LocalEventFeed.read(directory: directory, after: batch.cursor)
        XCTAssertFalse(disabled.enabled)
        XCTAssertTrue(disabled.events.isEmpty)
        XCTAssertTrue(disabled.gap)
        restart.configure(enabled: true, includeTitles: false)
        XCTAssertTrue(try LocalEventFeed.read(directory: directory).events.isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: feed.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testRetentionGapAndCorruptionRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = LocalEventFeed(directory: directory)
        feed.configure(enabled: true, includeTitles: false)
        let baseline = try LocalEventFeed.read(directory: directory).cursor
        feed.append((0..<502).map(event), includeTitles: false, now: now)
        let batch = try LocalEventFeed.read(directory: directory, after: baseline)
        XCTAssertTrue(batch.gap)
        XCTAssertEqual(batch.events.count, 500)
        feed.append([], includeTitles: false, now: now + 8 * 86_400)
        XCTAssertTrue(try LocalEventFeed.read(directory: directory).events.isEmpty)
        try Data("broken".utf8).write(to: feed.url)
        XCTAssertThrowsError(try LocalEventFeed.read(directory: directory))
        let recovered = LocalEventFeed(directory: directory)
        recovered.configure(enabled: false, includeTitles: false)
        XCTAssertFalse(try LocalEventFeed.read(directory: directory).enabled)
    }

    func testReferenceAdapterAndIndependentFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.json")
        let caps = ToolCapabilities(eventPhases: ["ended"], usage: false, navigation: "unsupported")
        let adapter = JSONFileToolAdapter(key: "sample", name: "示例", letter: "S", capabilities: caps, source: url)
        let broken = JSONFileToolAdapter(key: "broken", name: "读取失败", letter: "B", capabilities: caps,
                                        source: directory.appendingPathComponent("missing.json"))
        let sample = ToolStatus(key: "sample", letter: "S", name: "示例", state: "idle", busyItems: [],
                                detail: "本轮结束", latestTitle: nil, latestAge: nil, quota: nil,
                                activeItems: [], activities: [TaskActivity(id: "stable-end", sessionId: "s1",
                                title: "脱敏样例", phase: "ended", updatedAt: now)], capabilities: caps)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(sample).write(to: url)
        let values = AdapterContract.collect([broken, adapter, adapter], environment: CollectorEnvironment(now: now),
                                             settings: CollectorSettings())
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].health?.state, "error")
        XCTAssertEqual(values[1], sample)
        XCTAssertFalse(values[0].health!.message.contains(directory.path))
        XCTAssertTrue(AdapterContract.collect([adapter], excluding: ["sample"],
                          environment: CollectorEnvironment(now: now), settings: CollectorSettings()).isEmpty)
        let unsupported = ToolStatus(key: "sample", letter: "S", name: "示例", state: "idle", busyItems: [],
                                      detail: "", latestTitle: nil, latestAge: nil, quota: nil,
                                      activities: [TaskActivity(id: "fake", sessionId: "s1", title: "",
                                      phase: "waiting_permission", updatedAt: now)], capabilities: caps)
        XCTAssertThrowsError(try AdapterContract.validate(unsupported, adapter: adapter))
    }
}

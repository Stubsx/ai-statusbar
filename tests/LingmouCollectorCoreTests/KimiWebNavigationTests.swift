import Foundation
import XCTest
@testable import LingmouCollectorCore

final class KimiWebNavigationTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000
    private let sessionID = "session_12345678-1234-1234-1234-123456789abc"

    private func instance(_ id: String = "server-one", port: Int = 58627,
                          host: String = "127.0.0.1", heartbeat: Double? = nil) -> KimiWebInstance {
        KimiWebInstance(serverId: id, pid: 1234, host: host, port: port,
                        startedAt: (now - 100) * 1000, heartbeatAt: heartbeat ?? now * 1000)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func response(_ data: [String: Any]) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data]))
    }

    func testLoopbackOriginsAndUntrustedIDs() {
        XCTAssertEqual(instance().sessionURL(sessionID)?.absoluteString, "http://127.0.0.1:58627/sessions/\(sessionID)")
        XCTAssertEqual(instance(host: "0.0.0.0").origin?.host, "127.0.0.1")
        XCTAssertEqual(instance(host: "::").origin?.absoluteString, "http://[::1]:58627")
        for host in ["example.com", "127.0.0.1.example.com", "192.168.1.1", "user@localhost"] {
            XCTAssertNil(instance(host: host).origin)
        }
        for port in [-1, 0, 65536] { XCTAssertNil(instance(port: port).origin) }
        for id in ["", "../other", "a/b", "x?prompt=hello", "x#token=abc", "a%2fb", String(repeating: "x", count: 129)] {
            XCTAssertNil(instance().sessionURL(id))
        }
    }

    func testRegistryRejectsStaleReusedAndMalformedEntries() throws {
        let home = try temporaryHome()
        let directory = home.appendingPathComponent("server/instances")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ id: String, host: String = "127.0.0.1", heartbeat: Double, pid: Int = 1234) throws {
            let data: [String: Any] = ["server_id": id, "pid": pid, "host": host, "port": 58627,
                                       "started_at": (now - 1000) * 1000, "heartbeat_at": heartbeat]
            try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("\(id).json"))
        }
        try write("live", heartbeat: now * 1000)
        try write("stale", heartbeat: (now - 61) * 1000)
        try write("future", heartbeat: (now + 60) * 1000)
        try write("remote", host: "example.com", heartbeat: now * 1000)
        try write("reused", heartbeat: now * 1000, pid: 9999)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let found = KimiWebInstance.discover(home: home, now: now, processMatches: { $0.pid == 1234 })
        XCTAssertEqual(found.map(\.serverId), ["live"])
    }

    func testSharedHistoryDoesNotImplyDirectNavigation() throws {
        let home = try temporaryHome()
        let server = instance()
        var resolver = KimiWebResolver(home: home, instances: { [server] })
        resolver.ownsListener = { _ in true }
        resolver.transport = { request in
            switch request.url!.lastPathComponent {
            case "healthz": return self.response(["ok": true])
            case "connections": return self.response(["connections": []])
            default: return self.response(["id": self.sessionID, "busy": false])
            }
        }
        let result = resolver.resolve(sessionId: sessionID)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertNil(result.direct, "An idle history item needs an explicit choice of viewing location")
    }

    func testSubscribedOrBusySessionSelectsItsServerAmongSharedHistories() throws {
        let home = try temporaryHome()
        let servers = [instance(), instance("server-two", port: 58628)]
        for active in [false, true] {
            var resolver = KimiWebResolver(home: home, instances: { servers })
            resolver.ownsListener = { _ in true }
            resolver.transport = { request in
                let owner = request.url!.port == 58628
                switch request.url!.lastPathComponent {
                case "healthz": return self.response(["ok": true])
                case "connections": return self.response(["connections": owner && !active
                    ? [["subscriptions": [self.sessionID]]] : []])
                default: return self.response(["id": self.sessionID, "busy": owner && active])
                }
            }
            XCTAssertEqual(resolver.resolve(sessionId: sessionID).direct?.instance.port, 58628)
        }
    }

    func testMultipleConfirmedLocationsRequireChoice() throws {
        let home = try temporaryHome()
        let servers = [instance(), instance("server-two", port: 58628)]
        var resolver = KimiWebResolver(home: home, instances: { servers })
        resolver.ownsListener = { _ in true }
        resolver.transport = { request in
            request.url!.lastPathComponent == "healthz" ? self.response(["ok": true])
                : self.response(["id": self.sessionID, "busy": true])
        }
        let result = resolver.resolve(sessionId: sessionID)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertNil(result.direct)
    }

    func testTokenOnlyGoesToVerifiedListenerAndNeverIntoResult() throws {
        let home = try temporaryHome()
        try Data("fixture-token\n".utf8).write(to: home.appendingPathComponent("server.token"))
        let server = instance()
        var resolver = KimiWebResolver(home: home, instances: { [server] })
        var requests: [URLRequest] = []
        resolver.transport = { request in
            requests.append(request)
            switch request.url!.lastPathComponent {
            case "healthz": return self.response(["ok": true])
            case "connections": return self.response(["connections": []])
            default: return self.response(["id": self.sessionID, "busy": true])
            }
        }
        resolver.ownsListener = { _ in false }
        XCTAssertTrue(resolver.resolve(sessionId: sessionID).unavailable)
        XCTAssertTrue(requests.isEmpty)
        resolver.ownsListener = { _ in true }
        let url = try XCTUnwrap(resolver.resolve(sessionId: sessionID).direct?.url)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.query)
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "127.0.0.1" && $0.httpMethod == "GET" })
        XCTAssertFalse(requests.contains { ["snapshot", "runtime"].contains($0.url!.lastPathComponent) })
    }

    func testUnavailableAndMismatchedSessionsNeverOpenDifferentConversation() throws {
        let home = try temporaryHome()
        let server = instance()
        var resolver = KimiWebResolver(home: home, instances: { [server] })
        resolver.ownsListener = { _ in true }
        for failure in ["unauthorized", "html", "mismatch", "offline"] {
            resolver.transport = { request in
                if request.url!.lastPathComponent == "healthz" { return self.response(["ok": true]) }
                switch failure {
                case "unauthorized": return (401, Data())
                case "html": return (200, Data("<html>Kimi Code Web</html>".utf8))
                case "mismatch": return self.response(["id": "another-session", "busy": true])
                default: return nil
                }
            }
            let result = resolver.resolve(sessionId: sessionID)
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertTrue(result.unavailable)
        }
    }

    func testKimiLatestIDAndLifecycleSurviveBusyIdleAndOff() throws {
        let home = try temporaryHome()
        let directory = home.appendingPathComponent(".kimi-code/sessions/workspace/\(sessionID)")
        let agent = directory.appendingPathComponent("agents/main")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data(#"{"cwd":"/fixture/navigation-demo"}"#.utf8).write(to: directory.appendingPathComponent("state.json"))
        let wire = agent.appendingPathComponent("wire.jsonl")
        let start = #"{"type":"turn.prompt","time":2000000000000}"#
        let end = #"{"type":"context.append_loop_event","time":2000000000000,"event":{"type":"step.end","uuid":"one","turnId":"turn","finishReason":"end_turn"}}"#
        for (running, finished) in [(true, false), (true, true), (false, false)] {
            try Data((finished ? start + "\n" + end : start).utf8).write(to: wire)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: wire.path)
            let collector = LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                                            settings: CollectorSettings(), files: FileSupport(),
                                            processes: ProcessSupport { _, _, _ in running ? "/opt/bin/kimi\n" : "" })
            let state = collector.kimi()
            XCTAssertEqual(state.latest?.sessionId, sessionID)
            XCTAssertEqual(state.latest?.title, "navigation-demo")
            XCTAssertEqual(state.processOn, running)
            XCTAssertEqual(state.busy.isEmpty, finished || !running)
            XCTAssertEqual(state.activities.first?.phase, finished ? "ended" : nil)
        }
    }

    // MARK: - 浏览器标签页复用（方案 B：同源导航复用 + 自动回落）

    private func tab(_ window: Int, _ index: Int, _ url: String) -> BrowserTabAddress {
        BrowserTabAddress(windowIndex: window, tabIndex: index, url: url)
    }

    func testTabReuseParsingSkipsMalformedLines() {
        let output = [
            "1\t2\thttp://127.0.0.1:58627/sessions/a",
            "broken",
            "2\t1\t",
            "0\t1\thttp://127.0.0.1:58627/x",
            "3\t1\tmissing value",
        ].joined(separator: "\n")
        XCTAssertEqual(BrowserTabReuse.parseTabs(output),
                       [tab(1, 2, "http://127.0.0.1:58627/sessions/a")])
        XCTAssertEqual(BrowserTabReuse.parseTabs(""), [])
    }

    func testTabReuseNavigatesFrontmostSameOriginTab() {
        let target = URL(string: "http://127.0.0.1:58627/sessions/target")!
        let older = tab(1, 3, "http://127.0.0.1:58627/sessions/older")
        let plan = BrowserTabReuse.plan(tabs: [tab(2, 1, "http://127.0.0.1:58627/sessions/back"),
                                               older], target: target)
        XCTAssertEqual(plan, .navigate(older, to: "http://127.0.0.1:58627/sessions/target"))
    }

    func testTabReusePrefersExactTabOverSameOriginNavigation() {
        let target = URL(string: "http://127.0.0.1:58627/sessions/target")!
        let exact = tab(3, 1, target.absoluteString)
        XCTAssertEqual(BrowserTabReuse.plan(tabs: [tab(1, 1, "http://127.0.0.1:58627/sessions/other"),
                                                   exact], target: target),
                       .focus(exact))
    }

    func testTabReuseRejectsPrefixPortsAndForeignOrigins() {
        let target = URL(string: "http://127.0.0.1:58627/sessions/target")!
        XCTAssertEqual(BrowserTabReuse.plan(tabs: [
            tab(1, 1, "http://127.0.0.1:5863/sessions/target"),   // 端口只是前缀
            tab(1, 2, "https://127.0.0.1:58627/sessions/target"),  // 协议不同
            tab(1, 3, "http://localhost:58627/sessions/target"),   // 主机名不同
            tab(1, 4, "not a url"),
        ], target: target), .newTab)
    }

    func testTabReuseOriginTargetFocusesWithoutNavigatingBack() {
        let origin = URL(string: "http://127.0.0.1:58627")!
        let open = tab(1, 1, "http://127.0.0.1:58627/sessions/older")
        XCTAssertEqual(BrowserTabReuse.plan(tabs: [open], target: origin), .focus(open))
        XCTAssertEqual(BrowserTabReuse.plan(tabs: [tab(1, 1, "http://127.0.0.1:5863/")],
                                           target: origin), .newTab)
    }
}

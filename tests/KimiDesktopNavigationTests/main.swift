import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
let bridge = KimiDesktopNavigation.self
let port = 54321
check(bridge.parseRegistration("54321\n/devtools/browser/fixture-id")?.port == port, "valid registration")
for invalid in ["", "0\n/devtools/browser/id", "65536\n/devtools/browser/id", "54321\n/devtools/browser/../id",
                "54321\n/devtools/page/id", "54321\n/devtools/browser/id\nextra"] {
    check(bridge.parseRegistration(invalid) == nil, "reject invalid/stale registration shape")
}
let path = "/devtools/page/fixture-id"
check(bridge.validSocket("ws://127.0.0.1:54321" + path, port: port, path: path) != nil, "exact local socket")
for invalid in ["ws://localhost:54321", "ws://example.com:54321", "ws://127.0.0.1:54322", "wss://127.0.0.1:54321",
                "ws://user@127.0.0.1:54321"] {
    check(bridge.validSocket(invalid + path, port: port, path: path) == nil, "reject foreign socket")
}
for suffix in ["?token=secret", "#fragment", "/other"] {
    check(bridge.validSocket("ws://127.0.0.1:54321" + path + suffix, port: port, path: path) == nil, "exact path only")
}
let page: [String: Any] = ["id": "fixture-id", "type": "page", "title": "Kimi Code",
                           "url": "app://renderer/sessions/session_fixture", "webSocketDebuggerUrl": "ws://127.0.0.1:54321" + path]
check(bridge.pageSocket([page], port: port) != nil, "known main renderer")
check(bridge.pageSocket([page, page], port: port) == nil, "ambiguous renderers must not be guessed")
for raw in ["app://renderer/browser-overlay.html", "app://renderer/screenshot/index.html", "https://example.com/",
            "app://other/sessions/session_fixture", "app://renderer/sessions/a/b", "app://renderer/admin/sessions"] {
    var other = page; other["url"] = raw
    check(bridge.pageSocket([other], port: port) == nil, "reject secondary or foreign renderer")
}
for key in ["type", "title", "id", "webSocketDebuggerUrl"] {
    var other = page; other[key] = "untrusted"
    check(bridge.pageSocket([other], port: port) == nil, "reject inconsistent debugger target")
}
for id in ["", "../other", "session?prompt=hello", "x');evil();//", String(repeating: "a", count: 129)] {
    check(bridge.navigationExpression(sessionId: id, serverOrigins: []) == nil, "untrusted ID cannot enter JavaScript")
}
check(bridge.navigationExpression(sessionId: "session_valid-123", serverOrigins: []) != nil, "valid ID")
check(!bridge.openSession("session_fixture", pid: getpid(), applicationURL: URL(fileURLWithPath: "/Applications/Kimi Code.app"), waitForLaunch: false),
      "unrelated process must not control any debugger")
print("PASS: \(checks) Kimi desktop bridge checks for process identity, loopback sockets, ambiguous renderers and IDs")
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--live", let pid = Int32(CommandLine.arguments[2]) {
    let app = URL(fileURLWithPath: CommandLine.arguments[3])
    for id in CommandLine.arguments[4...5] {
        check(bridge.openSession(id, pid: pid, applicationURL: app, waitForLaunch: false), "live existing session must be selected")
    }
    check(!bridge.openSession("session_lingmou_nonexistent_probe", pid: pid, applicationURL: app, waitForLaunch: false), "missing session must be refused")
    print("PASS: live native bridge switched two existing sessions and rejected a missing session")
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--expression" {
    let expression = bridge.navigationExpression(sessionId: "session_target", serverOrigins: ["http://127.0.0.1:54322"])!
    try expression.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
}

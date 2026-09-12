// Foundation-only regression harness for the native App's actual tracker and JSON models.
import Foundation

var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    passed += 1
}

func item(_ id: String, title: String? = nil) -> BusyItem {
    BusyItem(id: id, title: title ?? "任务 \(id)")
}

func tool(_ items: [BusyItem] = [], count: Int? = nil,
          state: String? = nil, key: String = "test") -> ToolStatus {
    ToolStatus(key: key, letter: "T", name: "测试工具", state: state ?? (items.isEmpty ? "idle" : "busy"),
               busyCount: count ?? items.count, busyItems: items, detail: "", latestTitle: nil,
               latestAge: nil, quota: nil)
}

func ids(_ events: [InactiveTaskGroup]) -> [String] {
    events.flatMap { $0.items.map(\.id) }
}

// A known task disappears for three complete rounds: emit once, using its latest title.
do {
    var tracker = BusySessionTracker()
    check(tracker.observe([tool()]).isEmpty, "Starting idle must not emit historical tasks")
    check(tracker.observe([tool([item("a")])]).isEmpty, "Starting busy must not emit")
    check(tracker.observe([tool([item("a", title: "新标题")])]).isEmpty, "Renaming is not completion")
    check(tracker.observe([tool()]).isEmpty, "First missing round must wait")
    check(tracker.observe([tool()]).isEmpty, "Second missing round must wait")
    let events = tracker.observe([tool()])
    check(ids(events) == ["a"], "Third complete round must emit the known task")
    check(events.first?.items.first?.title == "新标题", "Notification must use the latest title")
    check(tracker.observe([tool()]).isEmpty, "A stopped task must not emit twice")
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    check(ids(tracker.observe([tool()])) == ["a"], "A new turn of the same session must be tracked")
}

// One of several tasks stops while another is still running.
do {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a"), item("b")])])
    _ = tracker.observe([tool([item("b")])])
    _ = tracker.observe([tool([item("b")])])
    check(ids(tracker.observe([tool([item("b")])])) == ["a"], "Partial completion must remain supported")
}

// Six tasks, but only five preview rows: rotating previews must never imply a stopped task.
do {
    var tracker = BusySessionTracker()
    let all = (1...6).map { item(String($0)) }
    for round in 0..<18 {
        let preview = all.enumerated().filter { $0.offset != (round / 3) % 6 }.map(\.element)
        check(tracker.observe([tool(preview, count: 6)]).isEmpty,
              "Truncated busy preview must not emit at round \(round)")
    }
    let remaining = Array(all.dropLast())
    check(tracker.observe([tool(remaining)]).isEmpty, "First complete snapshot must restart grace")
    check(tracker.observe([tool(remaining)]).isEmpty, "Second complete snapshot must still wait")
    check(ids(tracker.observe([tool(remaining)])) == ["6"], "Only a task missing from complete snapshots may emit")
}

// A truncated snapshot must break an already-running missing streak.
do {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    let preview = (1...5).map { item(String($0)) }
    check(tracker.observe([tool(preview, count: 6)]).isEmpty, "Truncation must interrupt missing evidence")
    check(tracker.observe([tool(preview)]).isEmpty, "A complete snapshot after truncation must start at one")
    check(tracker.observe([tool(preview)]).isEmpty, "A complete snapshot after truncation must reach two")
    check(ids(tracker.observe([tool(preview)])) == ["a"], "Require three new complete snapshots")
}

// A brief disappearance followed by resumed work resets the grace count.
do {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    check(tracker.observe([tool([item("a")])]).isEmpty, "Resuming must not emit")
    check(tracker.observe([tool()]).isEmpty, "Resume must clear the old missing streak")
    check(tracker.observe([tool()]).isEmpty, "Resume must require all grace rounds")
    check(ids(tracker.observe([tool()])) == ["a"], "A later stop must still be detected")
}

// Malformed counts, duplicate IDs and empty IDs cannot prove a task ended or crash the app.
for malformed in [
    tool([item("b"), item("b")], count: 2),
    tool([item(""), item("b")], count: 2),
    tool([item("  "), item("b")], count: 2),
    tool([item("b")], count: 2),
    tool([item("b"), item("c")], count: 1),
] {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    for _ in 0..<4 {
        check(tracker.observe([malformed]).isEmpty, "Malformed/incomplete snapshots must not emit")
    }
    check(tracker.observe([tool()]).isEmpty, "Malformed snapshots must break consecutive evidence")
}

// Tool offline, absent, or internally inconsistent: forget previous evidence.
for unavailable in [
    [tool(state: "off")],
    [],
    [tool(state: "unknown")],
    [tool(state: "busy")],
    [tool([item("a")], state: "idle")],
    [tool(count: -1)],
] {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    check(tracker.observe(unavailable).isEmpty, "Unavailable tools must not emit completion")
    for _ in 0..<4 {
        check(tracker.observe([tool()]).isEmpty, "Recovery must establish a fresh baseline")
    }
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    check(ids(tracker.observe([tool()])) == ["a"], "Recovered tools must track new activity normally")
}

// Collector failure invalidates all pending evidence; identical IDs across tools are independent.
do {
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("a")])])
    _ = tracker.observe([tool()])
    _ = tracker.observe([tool()])
    tracker.reset()
    for _ in 0..<4 {
        check(tracker.observe([tool()]).isEmpty, "Collector failure must reset pending activity")
    }
    _ = tracker.observe([tool([item("same")], key: "one"), tool([item("same")], key: "two")])
    _ = tracker.observe([tool(key: "one"), tool([item("same")], key: "two")])
    _ = tracker.observe([tool(key: "one"), tool([item("same")], key: "two")])
    let events = tracker.observe([tool(key: "one"), tool([item("same")], key: "two")])
    check(events.count == 1 && events.first?.toolKey == "one", "Tool identity must scope each session")
}

// Exercise the real snake_case wire format, including the collector's five-row preview limit.
do {
    let raw = Data("""
    {"key":"codex-cli","letter":"X","name":"Codex CLI","state":"busy","busy_count":6,
     "busy_items":[{"id":"1","title":"任务一"},{"id":"2","title":"任务二"},
                   {"id":"3","title":"任务三"},{"id":"4","title":"任务四"},{"id":"5","title":"任务五"}],
     "detail":"6 个任务"}
    """.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(ToolStatus.self, from: raw)
    var tracker = BusySessionTracker()
    _ = tracker.observe([tool([item("6")], key: "codex-cli")])
    for _ in 0..<4 {
        check(tracker.observe([decoded]).isEmpty, "A decoded truncated JSON snapshot must not emit")
    }
}

print("PASS: \(passed) checks for complete/truncated snapshots, grace resets, invalid IDs, offline recovery and JSON decoding")

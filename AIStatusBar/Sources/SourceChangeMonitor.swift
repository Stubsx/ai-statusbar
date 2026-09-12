import Foundation
import CoreServices

/// File events wake the local collector without polling historical usage or network.
/// A separate fallback timer covers process exits and dropped/coalesced filesystem events.
final class SourceChangeMonitor {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var databaseTimer: Timer?
    private var databaseStamps: [String: String] = [:]
    private var databases: [String] = []

    init(home: String = NSHomeDirectory(), onChange: @escaping () -> Void) {
        self.onChange = onChange
        let roots = [".codex", ".kimi-code", ".claude", ".hermes", ".zcode", ".dsh",
                     "Library/Application Support/kimi-desktop"].map { home + "/" + $0 }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<SourceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let dropped = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagRootChanged) != 0
            }
            if dropped || values.contains(where: SourceChangeMonitor.isStatusSource) { monitor.onChange() }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        let databaseRoots = [".hermes/state.db", ".zcode/cli/db/db.sqlite",
            "Library/Application Support/kimi-desktop/daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite"]
        databases = databaseRoots.flatMap { [home + "/" + $0, home + "/" + $0 + "-wal"] }
        pollDatabases(notify: false)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollDatabases() }
        databaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// SQLite can hold a WAL descriptor open for a whole turn. FSEvents may only
    /// notify on close; six stat calls catch writes without querying/scanning data.
    private func pollDatabases(notify: Bool = true) {
        var changed = false
        for path in databases {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let stamp = "\(modified):\(size):\(inode)"
            if databaseStamps[path] != stamp { changed = true; databaseStamps[path] = stamp }
        }
        if notify && changed { onChange() }
    }

    static func isStatusSource(_ path: String) -> Bool {
        if path.contains("/.codex/") {
            return path.contains("/sessions/") || path.contains("/state_") || path.hasSuffix("/session_index.jsonl")
        }
        if path.contains("/.hermes/") {
            return path.contains("/state.db") || path.hasSuffix("gateway.heartbeat")
        }
        if path.contains("/.zcode/") {
            return path.contains("/cli/db/") || path.contains("tasks-index.sqlite")
        }
        if path.contains("/kimi-desktop/") {
            return path.contains("/sessions/") || path.hasSuffix("conversation-statuses.json")
        }
        return path.contains("/.kimi-code/sessions/") || path.contains("/.claude/projects/")
            || path.contains("/.dsh/storages/") || path.contains("/.dsh/sessions/")
    }

    deinit {
        databaseTimer?.invalidate()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

import Foundation

/// Local event subscription v1. One app writer; readers never hold a lock or block collection.
public struct LocalEvent: Codable, Equatable, Sendable {
    public var sequence: Int
    public let id: String
    public let tool: String
    public let session: String
    public let timestamp: TimeInterval
    public let phase: String
    public let evidence: String
    public var title: String?

    public init(id: String, tool: String, session: String, timestamp: TimeInterval,
                phase: String, evidence: String, title: String? = nil) {
        sequence = 0
        self.id = id; self.tool = tool; self.session = session; self.timestamp = timestamp
        self.phase = phase; self.evidence = evidence; self.title = title
    }
}

public struct LocalEventBatch: Codable, Sendable {
    public let schema: Int
    public let enabled: Bool
    public let cursor: String
    public let gap: Bool
    public let events: [LocalEvent]
}

public final class LocalEventFeed {
    private struct Snapshot: Codable {
        var schema = 1
        var enabled = false
        var epoch = UUID().uuidString
        var sequence = 0
        var events: [LocalEvent] = []
    }
    public let url: URL
    public private(set) var storageError: String?
    private var snapshot = Snapshot()
    private var saved: Data?

    public init(directory: URL) {
        url = directory.appendingPathComponent("events-v1.json")
        if FileManager.default.fileExists(atPath: url.path) { saved = Data() }
        if let data = try? Data(contentsOf: url), data.count <= 8_000_000,
           let value = try? JSONDecoder().decode(Snapshot.self, from: data), value.schema == 1 {
            snapshot = value
            saved = data
        }
    }

    /// Policy changes remove retained titles immediately. Enabling starts a fresh epoch with no replay.
    public func configure(enabled: Bool, includeTitles: Bool) {
        if snapshot.enabled != enabled { snapshot = Snapshot(enabled: enabled) }
        if !includeTitles {
            for index in snapshot.events.indices { snapshot.events[index].title = nil }
        }
        // Default-off installations don't create an interface until it has been used.
        if enabled || saved != nil { persist() }
    }

    public func append(_ events: [LocalEvent], includeTitles: Bool, now: TimeInterval) {
        guard snapshot.enabled else { return }
        var seen = Set(snapshot.events.map(\.id))
        for var event in events {
            guard !event.id.isEmpty, event.id.utf8.count < 2_048, !event.session.isEmpty,
                  event.session.utf8.count < 2_048, event.tool.utf8.count < 80,
                  ["ended", "interrupted", "failed", "waiting_input", "waiting_permission", "inactive"].contains(event.phase),
                  ["explicit", "inferred"].contains(event.evidence), event.timestamp.isFinite,
                  event.timestamp >= now - 7 * 86_400, event.timestamp <= now + 60,
                  seen.insert(event.id).inserted else { continue }
            snapshot.sequence += 1
            event.sequence = snapshot.sequence
            event.title = includeTitles ? event.title.map { String($0.prefix(500)) } : nil
            snapshot.events.append(event)
        }
        snapshot.events = Array(snapshot.events.filter { $0.timestamp >= now - 7 * 86_400 }.suffix(500))
        persist()
    }

    /// nil reads retained history. Consumers resume from cursor; gap means epoch changed or retention expired.
    public static func read(directory: URL, after cursor: String? = nil) throws -> LocalEventBatch {
        let url = directory.appendingPathComponent("events-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LocalEventBatch(schema: 1, enabled: false, cursor: "disabled:0", gap: cursor != nil, events: [])
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 8_000_000 else { throw FeedError.invalid }
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard value.schema == 1, value.sequence >= 0 else { throw FeedError.invalid }
        var after = 0
        var gap = false
        if let cursor {
            let pieces = cursor.split(separator: ":", omittingEmptySubsequences: false)
            if pieces.count == 2, pieces[0] == value.epoch, let number = Int(pieces[1]),
               number >= 0, number <= value.sequence {
                after = number
                gap = number < (value.events.first?.sequence ?? (value.sequence + 1)) - 1
            } else { gap = true }
        }
        return LocalEventBatch(schema: 1, enabled: value.enabled,
                               cursor: "\(value.epoch):\(value.sequence)", gap: gap,
                               events: value.enabled ? value.events.filter { $0.sequence > after } : [])
    }

    public enum FeedError: Error { case invalid }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if data != saved {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                saved = data
            }
            storageError = nil
        } catch { storageError = "本地事件接口无法保存，请检查磁盘空间与目录权限" }
    }
}

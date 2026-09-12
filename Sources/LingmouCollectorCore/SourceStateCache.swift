import Foundation

/// Cache parsed evidence, never the final busy/idle decision. Process liveness,
/// freshness and titles are reevaluated on every collection.
final class SourceStateCache {
    private struct Entry: Codable {
        let modified: Double
        let size: UInt64
        let inode: UInt64
        let evidence: Data
    }
    private let path: String
    private var entries: [String: Entry]
    private var visited = Set<String>()
    private var changed = false

    init(home: String) {
        path = (home as NSString).appendingPathComponent(".ai-statusbar/source-state-v1.json")
        entries = FileSupport().read(path).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
    }

    func value<T: Codable>(at source: String, parse: () -> T) -> T {
        visited.insert(source)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: source)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if let entry = entries[source], entry.modified == modified, entry.size == size,
           entry.inode == inode, let value = try? JSONDecoder().decode(T.self, from: entry.evidence) {
            return value
        }
        let value = parse()
        if let data = try? JSONEncoder().encode(value) {
            entries[source] = Entry(modified: modified, size: size, inode: inode, evidence: data)
            changed = true
        }
        return value
    }

    func save() {
        let kept = entries.filter { visited.contains($0.key) }
        guard changed || kept.count != entries.count else { return }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileSupport().writePrivateData(data, to: path)
    }
}

import Foundation

/// Complete JSON snapshots shared by all frontends. The native app writes local
/// status on source changes, with a 5s fallback; historical usage and quota update separately every 30s.
/// SwiftBar/Übersicht keep their 10s cadence and reuse this file when available.
public enum CollectorCache {
    /// 与各前端 10 秒轮询同拍：再短起不到合并作用，再长会让无 App 时
    /// SwiftBar 自身的刷新明显滞后。
    public static let ttl: TimeInterval = 10

    public static func path(home: String) -> String {
        (home as NSString).appendingPathComponent(".ai-statusbar/collector-cache.json")
    }

    /// TTL 内的缓存内容；文件缺失、过期或不可读返回 nil，由调用方全量采集。
    public static func loadFresh(path: String, now: TimeInterval) -> Data? {
        let files = FileSupport()
        guard let modified = files.modificationTime(path), now - modified < ttl else {
            return nil
        }
        return files.read(path)
    }

    public static func save(_ data: Data, to path: String) {
        try? FileSupport().writePrivateData(data, to: path)
    }
}

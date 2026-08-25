import Foundation

/// 采集结果缓存：App / SwiftBar / Übersicht 各自每 10 秒拉起一次采集器，
/// 原先三份相同的全量扫描（7 个工具状态 + 子进程探测，单次约 0.5s CPU）。
/// 改为同一 TTL 窗口内只有首个到期的前端真正采集并落盘，其余前端直接
/// 复用文件内容。App 作为常驻宿主用 `--refresh` 跳过读缓存（保持自身
/// 10 秒节奏不变）并回写，供另外两个前端共享。
///
/// 缓存文件就是一份标准的 `--json` 输出，新鲜度用文件 mtime 判定，
/// 不混入额外字段，避免污染对外 JSON 契约。
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

import Foundation
import LingmouCollectorCore

// Authorization is a separate, explicitly invoked operation. It must never be
// combined with a periodic collection mode, and cannot wait indefinitely.
if CommandLine.arguments.contains("--authorize-kimi-keychain") {
    guard CommandLine.arguments.count == 2 else { exit(2) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { _exit(124) }
    exit(KimiKeychainAuthorization.request())
}

// --status-only reads local task state and cached enrichment without network/history scans.
// --metrics-only refreshes quota/usage without overwriting newer task state.
// Default collection and the complete shared JSON contract remain compatible.
let environment = CollectorEnvironment()
let cachePath = CollectorCache.path(home: environment.homeDirectory)

func collectAndCache() -> Data? {
    do {
        let collector = LingmouCollector(environment: environment)
        let metrics: CollectorMetrics?
        if CommandLine.arguments.contains("--status-only") {
            metrics = CollectorMetrics.load(home: environment.homeDirectory)
        } else {
            metrics = collector.collectMetrics()
            metrics?.save(home: environment.homeDirectory)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(collector.collectStatus(metrics: metrics))
        if !CommandLine.arguments.contains("--no-cache") { CollectorCache.save(data, to: cachePath) }
        return data
    } catch {
        FileHandle.standardError.write(
            Data("灵眸 Swift 采集器输出失败：\(error)\n".utf8))
        return nil
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--metrics-only") {
    LingmouCollector(environment: environment).collectMetrics().save(home: environment.homeDirectory)
    exit(0)
}
if arguments.contains("--events") {
    var cursor: String?
    if let index = arguments.firstIndex(of: "--after") {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("--after 需要 epoch:sequence 游标\n".utf8)); exit(2)
        }
        cursor = arguments[index + 1]
    }
    let directory = URL(fileURLWithPath: environment.homeDirectory).appendingPathComponent(".ai-statusbar")
    let follow = arguments.contains("--follow")
    do {
        // Without a saved cursor, follow starts at the current end, avoiding accidental history replay.
        if follow && cursor == nil { cursor = try LocalEventFeed.read(directory: directory).cursor }
        var first = true
        repeat {
            let batch = try LocalEventFeed.read(directory: directory, after: cursor)
            if first || batch.cursor != cursor || batch.gap || !batch.enabled {
                FileHandle.standardOutput.write(try JSONEncoder().encode(batch))
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            cursor = batch.cursor
            first = false
            if !batch.enabled { exit(3) }
            if follow { Thread.sleep(forTimeInterval: 1) }
        } while follow
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("本地事件读取失败或版本不兼容，请检查灵眸的连接与诊断。\n".utf8))
        exit(1)
    }
}

var data = (arguments.contains("--refresh") || arguments.contains("--status-only"))
    ? nil
    : CollectorCache.loadFresh(path: cachePath, now: environment.now)
if data == nil { data = collectAndCache() }
guard let data else { exit(1) }

if arguments.contains("--json") {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
} else {
    // SwiftBar 文本：从 JSON 渲染；缓存损坏解码失败时兜底再全量采集一次。
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let render: (Data) throws -> String = { raw in
        LingmouCollector(environment: environment).renderSwiftBar(
            try decoder.decode(StatusData.self, from: raw))
    }
    if let text = try? render(data) {
        print(text)
    } else if let fresh = collectAndCache(), let text = try? render(fresh) {
        print(text)
    } else {
        FileHandle.standardError.write(Data("灵眸 Swift 采集器输出失败：无法解析状态数据\n".utf8))
        exit(1)
    }
}

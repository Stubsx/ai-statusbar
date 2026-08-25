import Foundation
import LingmouCollectorCore

// App / SwiftBar / Übersicht 各自每 10 秒拉起本采集器；结果缓存让同一 TTL
// 窗口内只有首个到期的前端真正采集（约 0.5s CPU），其余直接复用缓存文件。
// App 作为常驻宿主用 --refresh 跳过读缓存（自身 10 秒节奏不变）并回写，
// 供另外两个前端共享，整体从每个前端各采一次收敛为每 10 秒至多一次。
let environment = CollectorEnvironment()
let cachePath = CollectorCache.path(home: environment.homeDirectory)

func collectAndCache() -> Data? {
    do {
        let data = try LingmouCollector(environment: environment).jsonData()
        CollectorCache.save(data, to: cachePath)
        return data
    } catch {
        FileHandle.standardError.write(
            Data("灵眸 Swift 采集器输出失败：\(error)\n".utf8))
        return nil
    }
}

let arguments = CommandLine.arguments
var data = arguments.contains("--refresh")
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

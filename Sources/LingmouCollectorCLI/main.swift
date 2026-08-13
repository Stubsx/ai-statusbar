import Foundation
import LingmouCollectorCore

let collector = LingmouCollector()
if CommandLine.arguments.contains("--json") {
    do {
        FileHandle.standardOutput.write(try collector.jsonData())
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        FileHandle.standardError.write(Data("灵眸 Swift 采集器输出失败：\(error)\n".utf8))
        exit(1)
    }
} else {
    print(collector.renderSwiftBar())
}

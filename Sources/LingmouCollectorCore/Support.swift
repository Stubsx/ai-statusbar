import Foundation

typealias JSONObject = [String: Any]

/// Synchronizes values shared with Foundation callbacks that may run concurrently.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum JSONValue {
    static func object(from data: Data) -> JSONObject? {
        try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    static func object(from text: String) -> JSONObject? {
        object(from: Data(text.utf8))
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

enum DateSupport {
    static func timestamp(_ value: Any?) -> TimeInterval? {
        guard let text = JSONValue.string(value), !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date.timeIntervalSince1970 }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: text)?.timeIntervalSince1970
    }

    static func localDay(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func displayDay(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

struct FileSupport {
    let manager: FileManager

    init(manager: FileManager = .default) {
        self.manager = manager
    }

    func modificationTime(_ path: String) -> TimeInterval? {
        guard let attrs = try? manager.attributesOfItem(atPath: path),
            let date = attrs[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }

    func fileSize(_ path: String) -> UInt64? {
        guard let attrs = try? manager.attributesOfItem(atPath: path),
            let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    func latest(matchingPrefix prefix: String, suffix: String, in directory: String) -> String? {
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return nil }
        return
            names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { (directory as NSString).appendingPathComponent($0) }
            .max { modificationTime($0) ?? 0 < modificationTime($1) ?? 0 }
    }

    func files(
        under root: String,
        where predicate: (String, Bool) -> Bool
    ) -> [String] {
        guard
            let enumerator = manager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if predicate(url.path, values?.isDirectory == true) { result.append(url.path) }
        }
        return result
    }

    func children(of root: String) -> [String] {
        (try? manager.contentsOfDirectory(atPath: root))?.map {
            (root as NSString).appendingPathComponent($0)
        } ?? []
    }

    /// 返回 root 下恰好指定层级的普通文件，用于保持 Python glob 的路径深度语义。
    func files(atDepth depth: Int, under root: String, where predicate: (String) -> Bool)
        -> [String]
    {
        guard depth > 0 else { return [] }
        var current = [root]
        if depth > 1 {
            for _ in 1..<depth {
                current = current.flatMap(children).filter { path in
                    var isDirectory: ObjCBool = false
                    return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
            }
        }
        return current.flatMap(children).filter { path in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && predicate(path)
        }
    }

    func read(_ path: String) -> Data? {
        manager.contents(atPath: path)
    }

    func readText(_ path: String) -> String? {
        guard let data = read(path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func readTail(_ path: String, bytes: Int = 256 * 1024) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    func jsonLines(_ text: String) -> [JSONObject] {
        text.split(whereSeparator: \.isNewline).compactMap {
            JSONValue.object(from: String($0).trimmingCharacters(in: .whitespaces))
        }
    }

    func ensurePrivateDirectory(_ path: String) throws {
        try manager.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    func writePrivateJSON(_ value: Any, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try ensurePrivateDirectory(directory)
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

struct ProcessSupport {
    var outputOverride: ((String, [String], TimeInterval) -> String)?

    init(outputOverride: ((String, [String], TimeInterval) -> String)? = nil) {
        self.outputOverride = outputOverride
    }

    func output(executable: String, arguments: [String], timeout: TimeInterval = 5) -> String {
        if let outputOverride { return outputOverride(executable, arguments, timeout) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let processGroup = DispatchGroup()
        processGroup.enter()
        process.terminationHandler = { _ in processGroup.leave() }
        do {
            try process.run()
        } catch {
            return ""
        }
        let dataGroup = DispatchGroup()
        let captured = LockedBox(Data())
        dataGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            captured.set(pipe.fileHandleForReading.readDataToEndOfFile())
            dataGroup.leave()
        }
        if processGroup.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = processGroup.wait(timeout: .now() + 1)
        }
        _ = dataGroup.wait(timeout: .now() + 1)
        return String(decoding: captured.get(), as: UTF8.self)
    }

    func count(named basename: String, excluding excluded: [String] = []) -> Int {
        output(executable: "/bin/ps", arguments: ["-eo", "args="])
            .split(whereSeparator: \.isNewline)
            .reduce(into: 0) { count, rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                while let first = tokens.first, first.contains("=") && !first.hasPrefix("/") {
                    tokens.removeFirst()
                }
                guard let first = tokens.first,
                    URL(fileURLWithPath: first).lastPathComponent == basename,
                    !excluded.contains(where: line.contains)
                else { return }
                count += 1
            }
    }
}

extension Double {
    var roundedTenth: Double { (self * 10).rounded() / 10 }
}

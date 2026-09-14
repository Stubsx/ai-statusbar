import Foundation
import Darwin

/// Local server registration is shared by the collector and the native router.
/// No credentials or machine-specific locations enter the collector JSON.
struct KimiWebInstance: Decodable, Equatable {
    let serverId: String
    let pid: Int32
    let host: String
    let port: Int
    let startedAt: Double
    let heartbeatAt: Double

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id", pid, host, port
        case startedAt = "started_at", heartbeatAt = "heartbeat_at"
    }

    var origin: URL? {
        guard ["127.0.0.1", "localhost", "0.0.0.0", "::1", "::"].contains(host),
              (1...65535).contains(port) else { return nil }
        let loopback = host.contains(":") ? "[::1]" : "127.0.0.1"
        return URL(string: "http://\(loopback):\(port)")
    }

    func sessionURL(_ id: String) -> URL? {
        guard Self.validID(id) else { return nil }
        return origin?.appendingPathComponent("sessions").appendingPathComponent(id)
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    func isFresh(at now: TimeInterval) -> Bool {
        origin != nil && Self.validID(serverId) && pid > 1
            && startedAt.isFinite && heartbeatAt.isFinite && startedAt > 0
            && heartbeatAt >= startedAt && heartbeatAt / 1000 <= now + 5
            && now - heartbeatAt / 1000 <= 60
    }

    /// Use the real executable, since Bun changes the process title to `kimi-cod`.
    /// A reused PID must not be newer than the registered server startup.
    func matchesProcess() -> Bool {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              Double(info.pbi_start_tvsec) <= startedAt / 1000 + 2 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return ["kimi", "kimi-code"].contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent)
    }

    static func discover(home: URL, now: TimeInterval = Date().timeIntervalSince1970,
                         processMatches: (KimiWebInstance) -> Bool = { $0.matchesProcess() }) -> [KimiWebInstance] {
        let directory = home.appendingPathComponent("server/instances")
        let paths = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var seen = Set<String>()
        return paths.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { path in
            guard path.pathExtension == "json",
                  let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
                  let data = try? Data(contentsOf: path),
                  let instance = try? JSONDecoder().decode(Self.self, from: data),
                  path.deletingPathExtension().lastPathComponent == instance.serverId,
                  instance.isFresh(at: now), processMatches(instance),
                  seen.insert("\(instance.pid):\(instance.port)").inserted else { return nil }
            return instance
        }
    }

    /// Only navigation checks the listening socket; periodic collection stays local and cheap.
    func ownsListener() -> Bool {
        guard matchesProcess() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0
            && String(decoding: output, as: UTF8.self).split(separator: "\n").contains("p\(pid)")
    }
}

struct KimiWebCandidate {
    let instance: KimiWebInstance
    let url: URL
    let confirmed: Bool
}

struct KimiWebResolution {
    var candidates: [KimiWebCandidate] = []
    var unavailable = false

    var direct: KimiWebCandidate? {
        candidates.count == 1 && candidates[0].confirmed ? candidates[0] : nil
    }
}

/// Called on demand off the main thread. GET session metadata never resumes a
/// session; /snapshot and /runtime are deliberately not used (they can load it).
struct KimiWebResolver {
    typealias Transport = (URLRequest) -> (Int, Data)?
    let home: URL
    var instances: () -> [KimiWebInstance]
    var ownsListener: (KimiWebInstance) -> Bool = { $0.ownsListener() }
    var transport: Transport = KimiWebHTTP.get

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code"),
         instances: (() -> [KimiWebInstance])? = nil) {
        self.home = home
        self.instances = instances ?? { KimiWebInstance.discover(home: home) }
    }

    func resolve(sessionId: String?) -> KimiWebResolution {
        if let sessionId, !KimiWebInstance.validID(sessionId) { return KimiWebResolution() }
        let live = instances()
        guard !live.isEmpty else { return KimiWebResolution() }
        // The token is only sent as a header to the verified local listener.
        // It is never included in browser URLs, results, logs or caches.
        let tokenPath = home.appendingPathComponent("server.token")
        let tokenSize = (try? tokenPath.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let token = tokenSize > 0 && tokenSize <= 16_384
            ? (try? String(contentsOf: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        var result = KimiWebResolution()
        for instance in live {
            guard ownsListener(instance), let origin = instance.origin,
                  let health = get(origin.appendingPathComponent("api/v1/healthz"), token: nil),
                  health["ok"] as? Bool == true else { result.unavailable = true; continue }
            guard let sessionId else {
                result.candidates.append(KimiWebCandidate(instance: instance, url: origin, confirmed: false))
                continue
            }
            guard let metadata = get(origin.appendingPathComponent("api/v1/sessions").appendingPathComponent(sessionId), token: token),
                  metadata["id"] as? String == sessionId,
                  let url = instance.sessionURL(sessionId) else { result.unavailable = true; continue }
            let connections = get(origin.appendingPathComponent("api/v1/connections"), token: token)?["connections"] as? [[String: Any]] ?? []
            let subscribed = connections.contains {
                ($0["subscriptions"] as? [String] ?? []).contains(sessionId)
            }
            let active = metadata["busy"] as? Bool == true || metadata["main_turn_active"] as? Bool == true
                || ["approval", "question"].contains(metadata["pending_interaction"] as? String ?? "")
            result.candidates.append(KimiWebCandidate(instance: instance, url: url, confirmed: subscribed || active))
        }
        // Shared history is not ownership. Prefer confirmed locations; if several
        // servers own the same session, the user chooses instead of guessing.
        let confirmed = result.candidates.filter(\.confirmed)
        if !confirmed.isEmpty { result.candidates = confirmed }
        return result
    }

    private func get(_ url: URL, token: String?) -> [String: Any]? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty, !token.contains("\n"), !token.contains("\r") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (status, data) = transport(request), status == 200, data.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 0 else { return nil }
        return object["data"] as? [String: Any]
    }
}

private final class KimiWebHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: (Int, Data)?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func get(_ request: URLRequest) -> (Int, Data)? {
        let handler = KimiWebHTTP()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration, delegate: handler, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            handler.lock.lock()
            if error == nil, let data, let response = response as? HTTPURLResponse {
                handler.result = (response.statusCode, data)
            }
            handler.lock.unlock()
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 3) == .success else { task.cancel(); return nil }
        handler.lock.lock()
        defer { handler.lock.unlock() }
        return handler.result
    }
}

import Cocoa
import Darwin

/// Opt-in bridge for Kimi Code 1.0.1's Electron renderer. Never runs during collection.
/// Only a loopback debugging socket owned by the exact Kimi app process is accepted.
enum KimiDesktopNavigation {
    static let launchArguments = ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0"]

    static func openSession(_ id: String, pid: Int32, applicationURL: URL, waitForLaunch: Bool) -> Bool {
        guard KimiWebInstance.validID(id), let executable = Bundle(url: applicationURL)?.executableURL else { return false }
        let deadline = Date().addingTimeInterval(waitForLaunch ? 6 : 0)
        repeat {
            guard matchesProcess(pid, executable: executable) else { return false }
            if let connection = endpoint(pid: pid),
               let expression = navigationExpression(sessionId: id, serverOrigins: connection.origins) {
                return evaluate(expression, at: connection.socket)
            }
            if !waitForLaunch || Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    private static func matchesProcess(_ pid: Int32, executable: URL) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 1, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
            == executable.resolvingSymlinksInPath()
    }

    private static func endpoint(pid: Int32) -> (socket: URL, origins: [String])? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-code-app/DevToolsActivePort")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let contents = try? String(contentsOf: file, encoding: .utf8),
              let registration = parseRegistration(contents) else { return nil }
        let ports = listenerPorts(pid: pid)
        guard ports.contains(registration.port) else { return nil }
        let origin = "http://127.0.0.1:\(registration.port)"
        let http = KimiDesktopHTTP()
        guard let version = http.get(URL(string: origin + "/json/version")!) as? [String: Any],
              let browserSocket = version["webSocketDebuggerUrl"] as? String,
              validSocket(browserSocket, port: registration.port, path: registration.path) != nil,
              let pages = http.get(URL(string: origin + "/json/list")!) as? [[String: Any]],
              let socket = pageSocket(pages, port: registration.port) else { return nil }
        return (socket, ports.filter { $0 != registration.port }.sorted().map { "http://127.0.0.1:\($0)" })
    }

    static func parseRegistration(_ text: String) -> (port: Int, path: String)? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].hasPrefix("/devtools/browser/"),
              KimiWebInstance.validID(String(lines[1].dropFirst("/devtools/browser/".count))) else { return nil }
        return (port, String(lines[1]))
    }

    static func validSocket(_ value: String, port: Int, path: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "ws", url.host == "127.0.0.1",
              url.port == port, url.path == path, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func pageSocket(_ pages: [[String: Any]], port: Int) -> URL? {
        let matches = pages.filter { page in
            guard page["type"] as? String == "page", page["title"] as? String == "Kimi Code",
                  let raw = page["url"] as? String, let url = URL(string: raw),
                  url.scheme == "app", url.host == "renderer", url.port == nil,
                  url.user == nil, url.password == nil else { return false }
            return url.path == "/" || (url.path.hasPrefix("/sessions/")
                && KimiWebInstance.validID(String(url.path.dropFirst("/sessions/".count))))
        }
        guard matches.count == 1, let page = matches.first,
              let id = page["id"] as? String, KimiWebInstance.validID(id),
              let raw = page["webSocketDebuggerUrl"] as? String else { return nil }
        return validSocket(raw, port: port, path: "/devtools/page/\(id)")
    }

    private static func listenerPorts(pid: Int32) -> Set<Int> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            guard $0.hasPrefix("n127.0.0.1:"), let port = Int($0.dropFirst("n127.0.0.1:".count)),
                  (1...65535).contains(port) else { return nil }
            return port
        })
    }

    /// Use Kimi's existing history handler, then verify its actual selected store ID.
    /// Preflight missing sessions before navigation: Kimi otherwise selects an unrelated fallback.
    static func navigationExpression(sessionId: String, serverOrigins: [String]) -> String? {
        guard KimiWebInstance.validID(sessionId),
              let data = try? JSONSerialization.data(withJSONObject: ["id": sessionId, "origins": serverOrigins]),
              let payload = String(data: data, encoding: .utf8) else { return nil }
        return """
        (async () => {
            const {id, origins} = \(payload);
            if (location.protocol !== 'app:' || location.host !== 'renderer') return false;
            let store;
            // A cold-launched renderer may expose CDP before its session UI is ready.
            for (let i = 0; i < 20; i++) {
                const pinia = document.querySelector('#app')?.__vue_app__?.config.globalProperties.$pinia;
                store = pinia?._s.get('kimi.sessions');
                if (store && document.querySelector('[contenteditable="true"],textarea')) break;
                await new Promise(resolve => setTimeout(resolve, 100));
            }
            if (!store || !Array.isArray(store.sessions)) return false;
            const original = store.activeSessionId;
            const originalURL = location.href;
            if (!store.sessions.some(s => s.id === id)) {
                const origin = sessionStorage.getItem('kimi-desktop-server-origin');
                if (!origins.includes(origin)) return false;
                const controller = new AbortController();
                const timer = setTimeout(() => controller.abort(), 1000);
                try {
                    const response = await fetch(origin + '/api/v1/sessions/' + encodeURIComponent(id), {
                        method: 'GET', redirect: 'error', credentials: 'omit', signal: controller.signal
                    });
                    if (!response.ok) return false;
                    const result = await response.json();
                    if (result.code !== 0 || result.data?.id !== id || result.data?.archived === true) return false;
                } catch { return false; } finally { clearTimeout(timer); }
            }
            // Do not steal navigation if the user changed sessions during the preflight.
            if (store.activeSessionId !== original || location.href !== originalURL) return false;
            const path = '/sessions/' + encodeURIComponent(id);
            if (store.activeSessionId !== id || location.pathname !== path) {
                history.pushState(null, '', path + location.search);
                dispatchEvent(new PopStateEvent('popstate'));
            }
            for (let i = 0; i < 25; i++) {
                if (store.activeSessionId === id && location.pathname === path) return true;
                if (location.pathname !== path) return false;
                await new Promise(resolve => setTimeout(resolve, 100));
            }
            return false;
        })()
        """
    }

    private static func evaluate(_ expression: String, at url: URL) -> Bool {
        let http = KimiDesktopHTTP()
        let session = http.session()
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: url)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "id": 1, "method": "Runtime.evaluate", "params": [
                "expression": expression, "awaitPromise": true, "returnByValue": true
            ]
        ]), let message = String(data: data, encoding: .utf8) else { return false }
        let response = KimiDesktopResponse()
        socket.resume()
        socket.send(.string(message)) { error in
            if error != nil { response.finish(nil); return }
            socket.receive { result in
                guard case .success(let message) = result else { response.finish(nil); return }
                switch message {
                case .string(let value): response.finish(Data(value.utf8))
                case .data(let data): response.finish(data)
                @unknown default: response.finish(nil)
                }
            }
        }
        guard let data = response.wait(seconds: 7),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? Int == 1, object["error"] == nil,
              let result = object["result"] as? [String: Any], result["exceptionDetails"] == nil,
              let value = result["result"] as? [String: Any] else { return false }
        return value["value"] as? Bool == true
    }
}

private final class KimiDesktopResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data: Data?
    func finish(_ value: Data?) {
        lock.lock(); data = value; lock.unlock()
        done.signal()
    }
    func wait(seconds: Double) -> Data? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

private final class KimiDesktopHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func get(_ url: URL) -> Any? {
        let client = session()
        defer { client.invalidateAndCancel() }
        let response = KimiDesktopResponse()
        client.dataTask(with: url) { data, result, error in
            guard error == nil, (result as? HTTPURLResponse)?.statusCode == 200,
                  let data, data.count <= 1_048_576 else { response.finish(nil); return }
            response.finish(data)
        }.resume()
        guard let data = response.wait(seconds: 1.5) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

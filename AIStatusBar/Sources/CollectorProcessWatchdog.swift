import Darwin
import Foundation

enum CollectorProcessWatchdog {
    @discardableResult
    static func schedule(_ process: Process, after seconds: TimeInterval) -> DispatchWorkItem {
        let work = DispatchWorkItem { stop(process) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // A stuck child may ignore SIGTERM. Bound the wait so polling cannot
        // leave a permanently occupied collection lane or orphaned request.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

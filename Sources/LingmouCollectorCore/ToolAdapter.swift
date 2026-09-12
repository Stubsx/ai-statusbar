import Foundation

/// Source-contributed adapters run in the collector. No executable plugins are discovered or installed.
public protocol ToolAdapter {
    var key: String { get }
    var name: String { get }
    var letter: String { get }
    var capabilities: ToolCapabilities { get }
    func collect(environment: CollectorEnvironment, settings: CollectorSettings) throws -> ToolStatus
}

public enum AdapterContract {
    public enum Violation: Error { case invalidIdentity, invalidSnapshot }

    public static func validate(_ value: ToolStatus, adapter: any ToolAdapter) throws {
        let validKey = !adapter.key.isEmpty && adapter.key.count <= 64
            && adapter.key.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        guard validKey, value.key == adapter.key, value.name == adapter.name,
              value.letter == adapter.letter else { throw Violation.invalidIdentity }
        let items = value.activeItems ?? value.busyItems
        let phases = Set(adapter.capabilities.eventPhases + ["working", "inactive"])
        guard ["busy", "idle", "off"].contains(value.state), items.count == value.busyCount,
              Set(items.map(\.id)).count == items.count, items.allSatisfy({ !$0.id.isEmpty }),
              (value.state == "busy") == !items.isEmpty,
              value.capabilities == adapter.capabilities,
              value.quota == nil || adapter.capabilities.quota,
              (value.activities ?? []).allSatisfy({
                  !$0.id.isEmpty && !$0.sessionId.isEmpty && $0.updatedAt.isFinite && $0.updatedAt > 0
                      && phases.contains($0.phase)
                      && ($0.evidence == "explicit" || ($0.phase == "inactive" && $0.evidence == "inferred"))
              }) else { throw Violation.invalidSnapshot }
    }

    /// Each throwing or invalid adapter degrades independently; raw error text may contain private paths.
    public static func collect(_ adapters: [any ToolAdapter], excluding reserved: Set<String> = [],
                               environment: CollectorEnvironment, settings: CollectorSettings) -> [ToolStatus] {
        var keys = reserved
        return adapters.compactMap { adapter in
            guard !adapter.key.isEmpty, adapter.key.count <= 64,
                  adapter.key.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
                  keys.insert(adapter.key).inserted else { return nil }
            do {
                let value = try adapter.collect(environment: environment, settings: settings)
                try validate(value, adapter: adapter)
                return value
            } catch {
                return ToolStatus(key: adapter.key, letter: adapter.letter, name: adapter.name,
                                  state: "off", busyItems: [], detail: "适配器读取失败", latestTitle: nil,
                                  latestAge: nil, quota: nil, activeItems: [], activities: [],
                                  health: ToolHealth(state: "error", message: "适配器数据不可读或不符合契约",
                                                     checkedAt: environment.now), capabilities: adapter.capabilities)
            }
        }
    }
}

/// Minimal reference: a bounded local JSON snapshot. This adapter is not enabled in the shipping CLI.
public struct JSONFileToolAdapter: ToolAdapter {
    public let key: String
    public let name: String
    public let letter: String
    public let capabilities: ToolCapabilities
    public let source: URL

    public init(key: String, name: String, letter: String, capabilities: ToolCapabilities, source: URL) {
        self.key = key; self.name = name; self.letter = letter
        self.capabilities = capabilities; self.source = source
    }

    public func collect(environment: CollectorEnvironment, settings: CollectorSettings) throws -> ToolStatus {
        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else {
            throw AdapterContract.Violation.invalidSnapshot
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ToolStatus.self, from: Data(contentsOf: source))
    }
}

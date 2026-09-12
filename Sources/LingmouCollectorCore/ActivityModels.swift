import Foundation

/// Additive protocol v1. Unknown phase/capability strings must be treated as unsupported.
public struct TaskActivity: Codable, Hashable, Sendable {
    public let id: String
    public let sessionId: String
    public let title: String
    public let phase: String
    public let updatedAt: TimeInterval
    public let evidence: String

    public init(id: String, sessionId: String, title: String, phase: String,
                updatedAt: TimeInterval, evidence: String = "explicit") {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.phase = phase
        self.updatedAt = updatedAt
        self.evidence = evidence
    }
}

public struct ToolCapabilities: Codable, Hashable, Sendable {
    public let eventPhases: [String]
    public let usage: Bool
    public let quota: Bool
    public let navigation: String

    public init(eventPhases: [String] = [], usage: Bool = true, quota: Bool = false,
                navigation: String = "application") {
        self.eventPhases = eventPhases
        self.usage = usage
        self.quota = quota
        self.navigation = navigation
    }
}

public struct ToolHealth: Codable, Hashable, Sendable {
    public let state: String
    public let message: String
    public let checkedAt: TimeInterval
    public let sourceUpdatedAt: TimeInterval?
    public let quotaState: String

    public init(state: String, message: String, checkedAt: TimeInterval,
                sourceUpdatedAt: TimeInterval? = nil, quotaState: String = "unsupported") {
        self.state = state
        self.message = message
        self.checkedAt = checkedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.quotaState = quotaState
    }
}

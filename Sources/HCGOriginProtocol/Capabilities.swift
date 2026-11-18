import Foundation

/// Capabilities a Connector may *request* during enrollment. Requesting is not
/// receiving: ERP decides what is granted, and Origin enforces only what was granted.
///
/// Command or task execution is deliberately NOT an enrollment capability. It belongs
/// to Agent Runtime and needs its own, separate authorisation. Origin refuses it at
/// enrollment time and the local development service refuses to grant it.
public struct CapabilityInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var enrollable: Bool
}

public enum Capability {
    /// Keep an authenticated connection to Origin and appear as online.
    public static let presence = "connection.presence"
    /// Send basic device status (OS version, battery, uptime) to Origin.
    public static let statusReport = "device.status.report"
    /// Execute commands or tasks. Never granted by enrollment (Agent Runtime only).
    public static let execution = "agent.execute"

    public static let catalogue: [CapabilityInfo] = [
        CapabilityInfo(id: presence, title: "Connection presence",
                       detail: "Hold an authenticated connection to this gateway and show as online.", enrollable: true),
        CapabilityInfo(id: statusReport, title: "Status reports",
                       detail: "Send OS version, battery and uptime to this gateway.", enrollable: true),
        CapabilityInfo(id: execution, title: "Command execution",
                       detail: "Not available through enrollment. Requires separate Agent Runtime authorisation.",
                       enrollable: false),
    ]

    public static func info(_ id: String) -> CapabilityInfo? { catalogue.first { $0.id == id } }

    public static func isEnrollable(_ id: String) -> Bool { info(id)?.enrollable == true }

    /// Execution-like capability names are refused even if a future catalogue misses them.
    public static func isExecutionLike(_ id: String) -> Bool {
        id == execution || id.hasPrefix("agent.") || id.contains("exec") || id.contains("command") || id.contains("shell")
    }

    /// Splits a request into what may be forwarded for a decision and what is refused here.
    public static func screen(_ requested: [String]) -> (forward: [String], refused: [CapabilityRefusal]) {
        var forward: [String] = []
        var refused: [CapabilityRefusal] = []
        for id in Array(Set(requested)).sorted() {
            if isExecutionLike(id) {
                refused.append(CapabilityRefusal(capability: id, reason: "execution_requires_agent_runtime",
                    message: "Command execution is never granted by device enrollment. It requires separate Agent Runtime authorisation."))
            } else if isEnrollable(id) {
                forward.append(id)
            } else {
                refused.append(CapabilityRefusal(capability: id, reason: "unknown_capability",
                    message: "This gateway does not know the capability \(id)."))
            }
        }
        return (forward, refused)
    }
}

public struct CapabilityRefusal: Codable, Equatable, Sendable {
    public var capability: String
    public var reason: String
    public var message: String
    public init(capability: String, reason: String, message: String) {
        self.capability = capability; self.reason = reason; self.message = message
    }
}

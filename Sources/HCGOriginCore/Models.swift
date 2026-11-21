import Foundation
import HCGOriginProtocol

public enum OriginVersion {
    public static let marketing = "0.2.0"
}

/// Which central service Origin talks to.
public enum CentralMode: String, Codable, Sendable, CaseIterable {
    /// Real HCG (HCG Connect sign-in + central admission through ERP). Unavailable until configured.
    case production
    /// The clearly labelled local development service on this computer. Not HCG.
    case development

    public var wireEnvironment: String { rawValue }
}

public struct OriginSettings: Codable, Equatable, Sendable {
    public var gatewayName: String
    public var listenPort: UInt16
    /// Accept Connector traffic from the local network. Off by default (this computer only).
    public var allowLocalNetwork: Bool
    public var centralMode: CentralMode
    public var developmentServiceURL: String
    public var invitationTTLSeconds: Int
    /// Keep the gateway running after the window closes (menu bar status item shows it).
    public var keepRunningInBackground: Bool
    public var heartbeatIntervalSeconds: Int
    /// A device with no authenticated contact for this long is shown as disconnected.
    public var disconnectAfterSeconds: Int
    /// How often Origin asks central for decisions and revocations.
    public var centralSyncSeconds: Int
    /// Undecided requests expire locally after this long.
    public var requestTTLSeconds: Int
    /// Devices may connect only while admission was confirmed with central within this many seconds.
    /// Optional so that older settings files still load; nil means the default (15 minutes).
    public var admissionMaxAgeSeconds: Int?

    public var admissionMaxAge: Int { admissionMaxAgeSeconds ?? 15 * 60 }
    /// HCG Server owner API this Origin manages (loopback only). Nil when not connected.
    public var hcgServer: HCGServerConnection?

    public static func defaults(hostName: String) -> OriginSettings {
        OriginSettings(gatewayName: hostName.isEmpty ? "HCG Origin" : hostName,
                       listenPort: 47_700, allowLocalNetwork: false, centralMode: .production,
                       developmentServiceURL: "http://127.0.0.1:47800/api/public/origin/v1",
                       invitationTTLSeconds: Int(InvitationCode.defaultTTL), keepRunningInBackground: false,
                       heartbeatIntervalSeconds: 10, disconnectAfterSeconds: 35, centralSyncSeconds: 4,
                       requestTTLSeconds: 30 * 60, admissionMaxAgeSeconds: nil, hcgServer: nil)
    }

    public var clampedInvitationTTL: TimeInterval {
        min(max(TimeInterval(invitationTTLSeconds), InvitationCode.minimumTTL), InvitationCode.maximumTTL)
    }
}

public enum InvitationStatus: String, Codable, Sendable { case active, used, expired, cancelled }

/// Origin keeps only the hash of an invitation secret.
public struct InvitationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var secretHash: String
    public var createdAt: Date
    public var expiresAt: Date
    public var status: InvitationStatus
    public var usedAt: Date?
    public var usedByFingerprint: String?
    public var failedProofs: Int
    public var environment: String
    public var address: String
}

/// One local verification step shown in Connection requests.
public struct VerificationStep: Codable, Equatable, Sendable, Identifiable {
    public enum Result: String, Codable, Sendable { case passed, failed, pending, notApplicable = "not_applicable" }
    public var id: String
    public var title: String
    public var result: Result
    public var detail: String?
    public var at: Date?
}

/// Local view of one enrollment request.
public struct EnrollmentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String // local request ID
    public var invitationId: String
    public var device: DeviceDescriptor
    public var deviceFingerprint: String
    public var observedFrom: String
    public var requestedCapabilities: [String]
    public var forwardedCapabilities: [String]
    public var refusedCapabilities: [CapabilityRefusal]
    public var checkCode: String
    public var receivedAt: Date
    public var expiresAt: Date
    public var state: EnrollmentState
    public var environment: String
    public var steps: [VerificationStep]
    /// The device's original signed request, kept so central can verify it independently.
    public var forwarded: ForwardedDeviceRequest
    public var centralEnrollmentId: String?
    public var centralState: String?
    public var lastCentralError: String?
    public var centralAttempts: Int
    public var nextCentralAttemptAt: Date?
    public var decidedAt: Date?
    public var decisionReason: String?
    public var issuedDeviceId: String?
    public var grant: DeviceGrant?

    public var isOpen: Bool { state == .received || state == .awaitingDecision }
}

public enum DeviceStatus: String, Codable, Sendable {
    case active
    /// Revoked centrally (ERP). Origin rejects all of its requests.
    case revoked
    /// Blocked on this gateway only. Does not change ERP admission.
    case blockedLocally = "blocked_locally"
}

public enum ConnectionState: String, Codable, Sendable {
    case awaitingFirstContact = "awaiting_first_contact"
    case connected
    case disconnected
    case revoked
    case blocked
}

public struct DeviceRecord: Codable, Equatable, Sendable, Identifiable {
    /// Central-issued device ID.
    public var id: String
    public var proposedDeviceId: String
    public var name: String
    public var platform: String
    public var model: String?
    public var softwareVersion: String
    public var clientKind: String
    public var fingerprint: String
    public var publicKey: String
    public var grant: DeviceGrant
    public var environment: String
    public var enrollmentRequestId: String
    public var enrolledAt: Date
    public var status: DeviceStatus
    public var statusChangedAt: Date?
    public var statusReason: String?
    public var lastContactAt: Date?
    public var lastContactFrom: String?
    public var lastSequence: Int?
    public var lastReport: DeviceStatusReport?
    public var connectedSince: Date?
    public var lastRejectedAt: Date?

    public func connectionState(now: Date, disconnectAfter: TimeInterval) -> ConnectionState {
        switch status {
        case .revoked: return .revoked
        case .blockedLocally: return .blocked
        case .active:
            guard let last = lastContactAt else { return .awaitingFirstContact }
            return now.timeIntervalSince(last) <= disconnectAfter ? .connected : .disconnected
        }
    }
}

public struct GatewayCentralRecord: Codable, Equatable, Sendable {
    public var gatewayId: String // issued by central
    public var environment: String
    public var serviceURL: String
    public var ownerAccountId: String
    public var registeredAt: Date
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case pairing, enrollment, decision, connection, revocation, security, central, account, gateway, error
}

public enum ActivitySeverity: String, Codable, Sendable { case info, success, warning, error }

public struct ActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var kind: ActivityKind
    public var severity: ActivitySeverity
    public var title: String
    public var detail: String
    public var environment: String
    public var deviceId: String?
    public var requestId: String?
}

public struct OriginState: Codable, Equatable, Sendable {
    public var invitations: [InvitationRecord] = []
    public var requests: [EnrollmentRecord] = []
    public var devices: [DeviceRecord] = []
    /// Registrations per environment ("production" / "development"), issued by central.
    public var registrations: [String: GatewayCentralRecord] = [:]
    public var pendingEvents: [GatewayEvent] = []
    /// Signed-in account per environment (non-secret profile; tokens live in the secret store).
    public var accounts: [String: CentralAccount] = [:]
    public init() {}
}

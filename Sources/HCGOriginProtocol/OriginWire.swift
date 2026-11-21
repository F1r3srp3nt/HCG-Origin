import Foundation

/// Connector ↔ Origin wire contract, version 1 (`hcg-origin/1`).
public enum OriginPath {
    public static let enroll = "/origin/v1/enroll"
    public static let enrollmentStatus = "/origin/v1/enrollment-status"
    public static let heartbeat = "/origin/v1/heartbeat"
}

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder().encode(value)) ?? Data("{}".utf8)
    }
}

public struct DeviceDescriptor: Codable, Equatable, Sendable {
    /// SubjectPublicKeyInfo (DER), base64url.
    public var publicKey: String
    /// Identifier the device proposes for itself. Central issues the real device ID.
    public var proposedDeviceId: String
    public var name: String
    public var platform: String
    public var model: String?
    public var softwareVersion: String
    /// "connector" for the HCG Connector app, "connector-test-client" for the development test client.
    public var clientKind: String

    public init(publicKey: String, proposedDeviceId: String, name: String, platform: String, model: String?,
                softwareVersion: String, clientKind: String) {
        self.publicKey = publicKey; self.proposedDeviceId = proposedDeviceId; self.name = name
        self.platform = platform; self.model = model; self.softwareVersion = softwareVersion; self.clientKind = clientKind
    }

    public var publicKeyDER: Data? { Encoding.fromBase64url(publicKey) }

    /// Basic sanity limits for self-reported, untrusted fields.
    public var isWellFormed: Bool {
        guard let der = publicKeyDER, SignatureVerifier.isValidPublicKey(der) else { return false }
        let fields = [proposedDeviceId, name, platform, softwareVersion, clientKind]
        return fields.allSatisfy { !$0.isEmpty && $0.count <= 128 } && (model?.count ?? 0) <= 128
    }
}

public struct EnrollRequestBody: Codable, Equatable, Sendable {
    public var type: String
    public var invitationId: String
    /// Must equal the fingerprint of the gateway that receives the request.
    public var gatewayFingerprint: String
    public var device: DeviceDescriptor
    public var requestedCapabilities: [String]

    public static let typeValue = "hcg.origin.enroll/1"

    public init(invitationId: String, gatewayFingerprint: String, device: DeviceDescriptor, requestedCapabilities: [String]) {
        self.type = Self.typeValue
        self.invitationId = invitationId
        self.gatewayFingerprint = gatewayFingerprint
        self.device = device
        self.requestedCapabilities = requestedCapabilities
    }
}

/// Lifecycle of an enrollment request as reported to the Connector.
public enum EnrollmentState: String, Codable, Sendable, CaseIterable {
    case received            // verified locally by Origin, not yet accepted by central
    case awaitingDecision = "awaiting_decision" // central accepted it; ERP decision pending
    case approved
    case rejected
    case expired
    case failed
}

public struct EnrollResponseBody: Codable, Equatable, Sendable {
    public var requestId: String
    public var state: EnrollmentState
    public var checkCode: String
    public var gatewayName: String
    public var gatewayFingerprint: String
    /// SPKI DER base64url. The Connector checks it hashes to the pinned fingerprint.
    public var gatewayPublicKey: String
    public var environment: String
    public var forwardedCapabilities: [String]
    public var refusedCapabilities: [CapabilityRefusal]
    public var message: String
    /// `InvitationTransport` value of this connection.
    public var transport: String
    /// The TLS key this response was served over, signed into the body by the gateway identity key
    /// (binds the encrypted channel to the gateway identity). Nil only for cleartext development.
    public var tlsFingerprint: String?

    public init(requestId: String, state: EnrollmentState, checkCode: String, gatewayName: String, gatewayFingerprint: String,
                gatewayPublicKey: String, environment: String, forwardedCapabilities: [String],
                refusedCapabilities: [CapabilityRefusal], message: String, transport: String, tlsFingerprint: String?) {
        self.transport = transport; self.tlsFingerprint = tlsFingerprint
        self.requestId = requestId; self.state = state; self.checkCode = checkCode; self.gatewayName = gatewayName
        self.gatewayFingerprint = gatewayFingerprint; self.gatewayPublicKey = gatewayPublicKey; self.environment = environment
        self.forwardedCapabilities = forwardedCapabilities; self.refusedCapabilities = refusedCapabilities; self.message = message
    }
}

public struct EnrollmentStatusRequestBody: Codable, Equatable, Sendable {
    public var type: String
    public var requestId: String
    public static let typeValue = "hcg.origin.enrollment-status/1"
    public init(requestId: String) { self.type = Self.typeValue; self.requestId = requestId }
}

/// What ERP granted. `executionAuthorized` is always false for enrollment grants.
public struct DeviceGrant: Codable, Equatable, Sendable {
    public var capabilities: [String]
    public var executionAuthorized: Bool
    public var grantedAt: Date
    public var expiresAt: Date?
    /// "hcg-erp" for production decisions, "local-development-service" for the dev stand-in.
    public var decidedBy: String

    public init(capabilities: [String], executionAuthorized: Bool = false, grantedAt: Date, expiresAt: Date? = nil, decidedBy: String) {
        self.capabilities = capabilities; self.executionAuthorized = executionAuthorized
        self.grantedAt = grantedAt; self.expiresAt = expiresAt; self.decidedBy = decidedBy
    }

    public func allows(_ capability: String) -> Bool { capabilities.contains(capability) }
}

public struct EnrollmentStatusResponseBody: Codable, Equatable, Sendable {
    public var requestId: String
    public var state: EnrollmentState
    /// Central connection detail while undecided, e.g. "unreachable", "submitted".
    public var centralState: String?
    public var reason: String?
    /// Issued by central on approval. Absent otherwise.
    public var deviceId: String?
    public var grant: DeviceGrant?
    public var environment: String
    public var message: String
    public var tlsFingerprint: String?

    public init(requestId: String, state: EnrollmentState, centralState: String?, reason: String?, deviceId: String?,
                grant: DeviceGrant?, environment: String, message: String, tlsFingerprint: String?) {
        self.tlsFingerprint = tlsFingerprint
        self.requestId = requestId; self.state = state; self.centralState = centralState; self.reason = reason
        self.deviceId = deviceId; self.grant = grant; self.environment = environment; self.message = message
    }
}

public struct DeviceStatusReport: Codable, Equatable, Sendable {
    public var osVersion: String?
    public var batteryPercent: Int?
    public var uptimeSeconds: Int?
    public init(osVersion: String?, batteryPercent: Int?, uptimeSeconds: Int?) {
        self.osVersion = osVersion; self.batteryPercent = batteryPercent; self.uptimeSeconds = uptimeSeconds
    }
}

public struct HeartbeatRequestBody: Codable, Equatable, Sendable {
    public var type: String
    public var deviceId: String
    public var sequence: Int
    /// Accepted only when `device.status.report` was granted.
    public var report: DeviceStatusReport?
    public static let typeValue = "hcg.origin.heartbeat/1"
    public init(deviceId: String, sequence: Int, report: DeviceStatusReport?) {
        self.type = Self.typeValue; self.deviceId = deviceId; self.sequence = sequence; self.report = report
    }
}

public struct HeartbeatResponseBody: Codable, Equatable, Sendable {
    public var state: String // "connected"
    public var grant: DeviceGrant
    public var intervalSeconds: Int
    public var serverTime: Date
    public var tlsFingerprint: String?

    public init(state: String, grant: DeviceGrant, intervalSeconds: Int, serverTime: Date, tlsFingerprint: String?) {
        self.tlsFingerprint = tlsFingerprint
        self.state = state; self.grant = grant; self.intervalSeconds = intervalSeconds; self.serverTime = serverTime
    }
}

/// Error body for every non-2xx answer from Origin (and the dev service).
public struct ErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
    }
    public var error: Detail
    public var requestId: String?
    /// Set by Origin. Optional when decoding so that main HCG's existing envelope
    /// `{"error":{"code","message"},"api_version":"v1"}` is understood too.
    public var protocolVersion: String?

    public init(code: String, message: String, requestId: String? = nil) {
        self.error = Detail(code: code, message: message)
        self.requestId = requestId
        self.protocolVersion = OriginProtocol.version
    }
}

/// Error codes returned by Origin's Connector-facing API.
public enum OriginErrorCode {
    public static let badRequest = "bad_request"
    public static let unauthenticated = "unauthenticated"
    public static let staleRequest = "stale_request"
    public static let replayedRequest = "replayed_request"
    public static let wrongGateway = "wrong_gateway"
    public static let invitationUnknown = "invitation_unknown"
    public static let invitationExpired = "invitation_expired"
    public static let invitationUsed = "invitation_used"
    public static let invitationCancelled = "invitation_cancelled"
    public static let invalidInvitationProof = "invalid_invitation_proof"
    public static let invalidSignature = "invalid_signature"
    public static let alreadyEnrolled = "already_enrolled"
    public static let enrollmentPending = "enrollment_pending"
    public static let unknownRequest = "unknown_request"
    public static let unknownDevice = "unknown_device"
    public static let deviceRevoked = "device_revoked"
    public static let deviceBlocked = "device_blocked_locally"
    public static let capabilityNotGranted = "capability_not_granted"
    public static let notFound = "not_found"
    public static let pairingUnavailable = "pairing_unavailable"
    /// Origin has not confirmed the device's admission with central recently enough (fail closed).
    public static let admissionUnverified = "admission_unverified"
    public static let localNetworkDisabled = "local_network_disabled"
    public static let addressNotAllowed = "address_not_allowed"
    public static let environmentInactive = "environment_inactive"

    public static let all: [String] = [
        badRequest, unauthenticated, staleRequest, replayedRequest, wrongGateway, invitationUnknown, invitationExpired,
        invitationUsed, invitationCancelled, invalidInvitationProof, invalidSignature, alreadyEnrolled, enrollmentPending,
        unknownRequest, unknownDevice, deviceRevoked, deviceBlocked, capabilityNotGranted, notFound, pairingUnavailable,
        admissionUnverified, localNetworkDisabled, addressNotAllowed, environmentInactive,
    ]
}

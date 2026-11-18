import Foundation

/// Origin ↔ central HCG contract — **PROPOSED, not issued.**
///
/// No such endpoints exist on the main HCG site today (see docs/CENTRAL-HANDOFF.md).
/// This file is the reference shape that the local development service implements
/// and that the main HCG project is asked to implement. Paths are relative to a
/// configured base URL; Origin never hardcodes a production base URL.
///
/// Every request carries:
///   * `Authorization: Bearer <access token>` — the signed-in person's HCG Connect token
///     (production) or a local development token (development service);
///   * the gateway's signature headers (`SignedEnvelope.signRequest`) made with the
///     gateway key registered through `POST gateways`.
public enum CentralPath {
    public static let health = "health"
    public static let account = "account"
    public static let gateways = "gateways"
    public static let enrollments = "enrollments"
    public static func enrollment(_ id: String) -> String { "enrollments/\(id)" }
    public static func gatewayDevices(_ gatewayId: String) -> String { "gateways/\(gatewayId)/devices" }
    public static func gatewayEvents(_ gatewayId: String) -> String { "gateways/\(gatewayId)/events" }
}

public struct CentralHealth: Codable, Equatable, Sendable {
    public var service: String
    /// "production" or "development". Origin refuses a mismatch with its configuration.
    public var environment: String
    public var apiVersion: String
    public var time: Date
    public init(service: String, environment: String, apiVersion: String, time: Date) {
        self.service = service; self.environment = environment; self.apiVersion = apiVersion; self.time = time
    }
}

public struct CentralAccount: Codable, Equatable, Sendable {
    public var accountId: String
    public var email: String
    public var displayName: String
    /// Whether central has verified this account (e.g. email confirmed, not suspended).
    public var verified: Bool
    /// Whether this account may own gateways and receive device enrollments.
    public var mayOwnGateways: Bool
    public var environment: String
    public init(accountId: String, email: String, displayName: String, verified: Bool, mayOwnGateways: Bool, environment: String) {
        self.accountId = accountId; self.email = email; self.displayName = displayName
        self.verified = verified; self.mayOwnGateways = mayOwnGateways; self.environment = environment
    }
}

public struct GatewayRegistrationRequest: Codable, Equatable, Sendable {
    public var gatewayPublicKey: String // SPKI DER base64url
    public var proposedGatewayId: String
    public var name: String
    public var platform: String
    public var originVersion: String
    public init(gatewayPublicKey: String, proposedGatewayId: String, name: String, platform: String, originVersion: String) {
        self.gatewayPublicKey = gatewayPublicKey; self.proposedGatewayId = proposedGatewayId
        self.name = name; self.platform = platform; self.originVersion = originVersion
    }
}

public struct GatewayRegistration: Codable, Equatable, Sendable {
    /// Issued by central. Never derived locally.
    public var gatewayId: String
    public var gatewayFingerprint: String
    public var ownerAccountId: String
    public var status: String // "registered" | "suspended"
    public var registeredAt: Date
    public var environment: String
    public init(gatewayId: String, gatewayFingerprint: String, ownerAccountId: String, status: String, registeredAt: Date, environment: String) {
        self.gatewayId = gatewayId; self.gatewayFingerprint = gatewayFingerprint; self.ownerAccountId = ownerAccountId
        self.status = status; self.registeredAt = registeredAt; self.environment = environment
    }
}

/// The Connector's original signed request, forwarded unchanged so central can
/// verify the device signature itself instead of trusting Origin.
public struct ForwardedDeviceRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var timestamp: Int64
    public var nonce: String
    public var keyFingerprint: String
    public var body: String // base64url of the exact body bytes
    public var signature: String // base64url DER
    public init(method: String, path: String, timestamp: Int64, nonce: String, keyFingerprint: String, body: String, signature: String) {
        self.method = method; self.path = path; self.timestamp = timestamp; self.nonce = nonce
        self.keyFingerprint = keyFingerprint; self.body = body; self.signature = signature
    }
}

public struct CentralEnrollmentSubmission: Codable, Equatable, Sendable {
    public var gatewayId: String
    public var localRequestId: String
    public var invitationId: String
    public var device: DeviceDescriptor
    public var requestedCapabilities: [String]
    public var refusedByGateway: [CapabilityRefusal]
    public var deviceRequest: ForwardedDeviceRequest
    public var receivedAt: Date
    public init(gatewayId: String, localRequestId: String, invitationId: String, device: DeviceDescriptor,
                requestedCapabilities: [String], refusedByGateway: [CapabilityRefusal],
                deviceRequest: ForwardedDeviceRequest, receivedAt: Date) {
        self.gatewayId = gatewayId; self.localRequestId = localRequestId; self.invitationId = invitationId
        self.device = device; self.requestedCapabilities = requestedCapabilities
        self.refusedByGateway = refusedByGateway; self.deviceRequest = deviceRequest; self.receivedAt = receivedAt
    }
}

public enum CentralEnrollmentState: String, Codable, Sendable {
    case pendingReview = "pending_review"
    case approved
    case rejected
    case expired
}

public struct CentralVerification: Codable, Equatable, Sendable {
    /// "verified" | "unverified" | "not_permitted"
    public var account: String
    /// "valid" | "invalid"
    public var deviceSignature: String
    public var gatewaySignature: String
    public init(account: String, deviceSignature: String, gatewaySignature: String) {
        self.account = account; self.deviceSignature = deviceSignature; self.gatewaySignature = gatewaySignature
    }
}

public struct CentralEnrollmentRecord: Codable, Equatable, Sendable {
    /// Issued by central.
    public var enrollmentId: String
    public var localRequestId: String
    public var state: CentralEnrollmentState
    public var verification: CentralVerification
    public var reason: String?
    public var decidedAt: Date?
    /// Issued by central on approval.
    public var deviceId: String?
    public var grant: DeviceGrant?
    public var environment: String
    public init(enrollmentId: String, localRequestId: String, state: CentralEnrollmentState, verification: CentralVerification,
                reason: String?, decidedAt: Date?, deviceId: String?, grant: DeviceGrant?, environment: String) {
        self.enrollmentId = enrollmentId; self.localRequestId = localRequestId; self.state = state
        self.verification = verification; self.reason = reason; self.decidedAt = decidedAt
        self.deviceId = deviceId; self.grant = grant; self.environment = environment
    }
}

public enum CentralDeviceStatus: String, Codable, Sendable { case active, revoked }

public struct CentralDeviceRecord: Codable, Equatable, Sendable {
    public var deviceId: String
    public var fingerprint: String
    public var name: String
    public var status: CentralDeviceStatus
    public var grant: DeviceGrant
    public var ownerAccountId: String
    public var revokedAt: Date?
    public var revocationReason: String?
    public init(deviceId: String, fingerprint: String, name: String, status: CentralDeviceStatus, grant: DeviceGrant,
                ownerAccountId: String, revokedAt: Date?, revocationReason: String?) {
        self.deviceId = deviceId; self.fingerprint = fingerprint; self.name = name; self.status = status
        self.grant = grant; self.ownerAccountId = ownerAccountId; self.revokedAt = revokedAt; self.revocationReason = revocationReason
    }
}

public struct CentralDeviceList: Codable, Equatable, Sendable {
    public var gatewayId: String
    public var devices: [CentralDeviceRecord]
    public init(gatewayId: String, devices: [CentralDeviceRecord]) { self.gatewayId = gatewayId; self.devices = devices }
}

/// Audit events Origin reports to central. Never contain secrets, tokens or invitation codes.
public struct GatewayEvent: Codable, Equatable, Sendable {
    public var eventId: String
    public var type: String
    public var occurredAt: Date
    public var deviceId: String?
    public var localRequestId: String?
    public var detail: String
    public init(eventId: String, type: String, occurredAt: Date, deviceId: String?, localRequestId: String?, detail: String) {
        self.eventId = eventId; self.type = type; self.occurredAt = occurredAt
        self.deviceId = deviceId; self.localRequestId = localRequestId; self.detail = detail
    }
}

public struct GatewayEventBatch: Codable, Equatable, Sendable {
    public var events: [GatewayEvent]
    public init(events: [GatewayEvent]) { self.events = events }
}

/// Central error codes (proposed), returned as `ErrorBody`.
public enum CentralErrorCode {
    public static let unauthorized = "unauthorized"
    public static let accountNotPermitted = "account_not_permitted"
    public static let gatewayNotRegistered = "gateway_not_registered"
    public static let gatewaySignatureInvalid = "gateway_signature_invalid"
    public static let deviceSignatureInvalid = "device_signature_invalid"
    public static let duplicateEnrollment = "duplicate_enrollment"
    public static let serviceUnavailable = "service_unavailable"
    public static let notFound = "not_found"
    public static let invalidInput = "invalid_input"
}

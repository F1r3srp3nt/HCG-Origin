import Foundation

/// The content of a pairing invitation, shown by Origin as a code and QR code.
///
/// An invitation is a short-lived, single-use capability to *submit* an enrollment
/// request. It never approves anything: approval is decided centrally (ERP).
/// Origin stores only a hash of `secret`; the Connector never sends the secret back,
/// it proves possession with an HMAC over each enrollment request.
/// How the Connector must connect to the gateway named in an invitation.
public enum InvitationTransport {
    /// HTTPS with TLS 1.3 only; the server certificate's SPKI SHA-256 must equal `tfp`.
    public static let tls13Pinned = "tls13-pinned"
    /// Cleartext HTTP to 127.0.0.1, development only (Linux test harness). Never issued by the macOS app,
    /// and a Connector must refuse it for any non-loopback address or the production environment.
    public static let cleartextLoopbackDevelopment = "cleartext-loopback-dev"
}

public struct InvitationPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var invitationId: String
    /// 256-bit random secret, base64url.
    public var secret: String
    /// Pinned gateway key fingerprint (SHA-256 of SPKI, hex).
    public var gatewayFingerprint: String
    public var gatewayName: String
    /// host:port where the Connector reaches Origin's enrollment endpoint.
    public var address: String
    /// Unix seconds.
    public var expiresAt: Int64
    /// "development" or "production". A Connector must show this to the person.
    public var environment: String
    /// `InvitationTransport` value.
    public var transport: String
    /// Pinned TLS certificate key fingerprint (SHA-256 of SPKI, hex). Required for `tls13-pinned`.
    public var tlsFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case version = "v", invitationId = "id", secret = "s", gatewayFingerprint = "gfp"
        case gatewayName = "gn", address = "addr", expiresAt = "exp", environment = "env"
        case transport = "t", tlsFingerprint = "tfp"
    }

    public init(invitationId: String, secret: String, gatewayFingerprint: String, gatewayName: String,
                address: String, expiresAt: Int64, environment: String,
                transport: String, tlsFingerprint: String?) {
        self.version = 2
        self.transport = transport
        self.tlsFingerprint = tlsFingerprint
        self.invitationId = invitationId
        self.secret = secret
        self.gatewayFingerprint = gatewayFingerprint
        self.gatewayName = gatewayName
        self.address = address
        self.expiresAt = expiresAt
        self.environment = environment
    }
}

public enum InvitationError: Error, Equatable, CustomStringConvertible {
    case wrongPrefix, corrupted, unsupportedVersion(Int), incomplete, expired, insecureTransport

    public var description: String {
        switch self {
        case .wrongPrefix: return "Not an HCG Origin pairing invitation (expected prefix \(InvitationCode.prefix))."
        case .corrupted: return "The invitation code is corrupted."
        case .unsupportedVersion(let v): return "Unsupported invitation version \(v)."
        case .incomplete: return "The invitation code is incomplete."
        case .expired: return "The invitation has expired. Ask for a new one in HCG Origin."
        case .insecureTransport: return "The invitation does not require an encrypted, pinned connection for this address. Refusing it."
        }
    }
}

public enum InvitationCode {
    public static let prefix = "hcgo2-"
    public static let defaultTTL: TimeInterval = 5 * 60
    public static let maximumTTL: TimeInterval = 15 * 60
    public static let minimumTTL: TimeInterval = 60

    public static func newSecret() -> String { Encoding.base64url(Encoding.randomBytes(32)) }

    /// Stored form of a secret. Origin keeps only this.
    public static func hashSecret(_ secret: String) -> String {
        Encoding.sha256Hex(Data(("hcg-origin-invitation-secret-v1:" + secret).utf8))
    }

    public static func encode(_ payload: InvitationPayload) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return prefix + Encoding.base64url(try enc.encode(payload))
    }

    /// Decodes and validates structure. Does not check expiry; use `validate(_:now:)`.
    public static func decode(_ code: String) throws -> InvitationPayload {
        let compact = code.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.hasPrefix(prefix) else { throw InvitationError.wrongPrefix }
        guard let data = Encoding.fromBase64url(String(compact.dropFirst(prefix.count))),
              let payload = try? JSONDecoder().decode(InvitationPayload.self, from: data) else {
            throw InvitationError.corrupted
        }
        guard payload.version == 2 else { throw InvitationError.unsupportedVersion(payload.version) }
        guard !payload.invitationId.isEmpty, !payload.address.isEmpty,
              Encoding.fromBase64url(payload.secret)?.count == 32,
              KeyFingerprint.isValid(payload.gatewayFingerprint),
              ["development", "production"].contains(payload.environment) else {
            throw InvitationError.incomplete
        }
        switch payload.transport {
        case InvitationTransport.tls13Pinned:
            guard let tfp = payload.tlsFingerprint, KeyFingerprint.isValid(tfp) else { throw InvitationError.incomplete }
        case InvitationTransport.cleartextLoopbackDevelopment:
            let host = payload.address.split(separator: ":").first.map(String.init) ?? ""
            guard host.hasPrefix("127."), payload.environment == "development", payload.tlsFingerprint == nil else {
                throw InvitationError.insecureTransport
            }
        default:
            throw InvitationError.insecureTransport
        }
        return payload
    }

    public static func validate(_ payload: InvitationPayload, now: Date = Date()) throws {
        if Int64(now.timeIntervalSince1970) >= payload.expiresAt { throw InvitationError.expired }
    }

    /// Key used for the possession proof (HMAC) of an invitation secret.
    public static func proofKey(secret: String, invitationId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data("hcg-origin-invitation-proof-v1".utf8),
            info: Data(invitationId.utf8),
            outputByteCount: 32
        )
    }

    public static func proof(secret: String, invitationId: String, signingInput: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: signingInput, using: proofKey(secret: secret, invitationId: invitationId))
        return Encoding.base64url(Data(mac))
    }

    public static func verifyProof(_ proof: String, secret: String, invitationId: String, signingInput: Data) -> Bool {
        guard let mac = Encoding.fromBase64url(proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signingInput,
                                                      using: proofKey(secret: secret, invitationId: invitationId))
    }
}

/// A six-digit code both Origin and the Connector display, so the person can
/// confirm that the request in Origin is the one their device sent.
public enum PairingCheckCode {
    public static func compute(gatewayFingerprint: String, deviceFingerprint: String, invitationId: String) -> String {
        let input = Data("hcg-origin-check-v1|\(gatewayFingerprint)|\(deviceFingerprint)|\(invitationId)".utf8)
        let digest = Array(SHA256.hash(data: input))
        let n = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return String(s.prefix(3)) + " " + String(s.suffix(3))
    }
}

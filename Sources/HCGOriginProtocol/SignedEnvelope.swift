import Foundation

/// HTTP header names used by the HCG Origin protocol (lowercase, as compared).
public enum OriginHeader {
    public static let protocolVersion = "x-hcg-protocol"
    public static let keyFingerprint = "x-hcg-key-fingerprint"
    public static let timestamp = "x-hcg-timestamp"
    public static let nonce = "x-hcg-nonce"
    public static let signature = "x-hcg-signature"
    public static let invitationProof = "x-hcg-invitation-proof"
    public static let requestNonce = "x-hcg-request-nonce"
    /// Responder's SPKI (base64url). Clients accept it only if it hashes to the pinned fingerprint.
    public static let publicKey = "x-hcg-public-key"
}

/// Versions of the HCG Origin contract. Connector, Origin and central HCG must agree on all three.
public enum HCGOriginContract {
    /// The contract revision documented in docs/PROTOCOL.md and docs/CENTRAL-HANDOFF.md.
    public static let revision = "hcg-origin-contract/2"
    /// Connector ↔ Origin.
    public static let connectorProtocol = OriginProtocol.version
    /// Origin ↔ central HCG (PROPOSED; returned as `apiVersion` by `GET health`).
    public static let centralAPI = "hcg-origin-central/1"
    /// Capability catalogue version.
    public static let capabilityCatalogue = "hcg-origin-capabilities/1"
}

public enum OriginProtocol {
    public static let version = "hcg-origin/2"
    /// Accepted clock difference between signer and verifier.
    public static let maxClockSkew: TimeInterval = 120
    /// How long a used nonce is remembered (must exceed 2 × maxClockSkew).
    public static let nonceRetention: TimeInterval = 300
}

/// What a signer covers in a request. Binding method, path, time, nonce, signer key
/// and a body digest prevents replaying a signature on another endpoint or body.
public struct RequestSigningInput: Equatable, Sendable {
    public var method: String
    public var path: String
    public var timestamp: Int64
    public var nonce: String
    public var keyFingerprint: String
    public var bodySHA256: String

    public init(method: String, path: String, timestamp: Int64, nonce: String, keyFingerprint: String, body: Data) {
        self.method = method.uppercased()
        self.path = path
        self.timestamp = timestamp
        self.nonce = nonce
        self.keyFingerprint = keyFingerprint
        self.bodySHA256 = Encoding.sha256Hex(body)
    }

    public var bytes: Data {
        Data("HCG-ORIGIN-REQUEST-V1\n\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(keyFingerprint)\n\(bodySHA256)".utf8)
    }
}

/// What a signer covers in a response: binds the response to the request nonce,
/// so a recorded response cannot be replayed to answer another request.
public struct ResponseSigningInput: Equatable, Sendable {
    public var status: Int
    public var requestNonce: String
    public var timestamp: Int64
    public var keyFingerprint: String
    public var bodySHA256: String

    public init(status: Int, requestNonce: String, timestamp: Int64, keyFingerprint: String, body: Data) {
        self.status = status
        self.requestNonce = requestNonce
        self.timestamp = timestamp
        self.keyFingerprint = keyFingerprint
        self.bodySHA256 = Encoding.sha256Hex(body)
    }

    public var bytes: Data {
        Data("HCG-ORIGIN-RESPONSE-V1\n\(status)\n\(requestNonce)\n\(timestamp)\n\(keyFingerprint)\n\(bodySHA256)".utf8)
    }
}

public enum SignedEnvelope {
    public static func newNonce() -> String { Encoding.base64url(Encoding.randomBytes(16)) }

    public static func isWellFormedNonce(_ nonce: String) -> Bool {
        (16...64).contains(nonce.count) && nonce.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Headers for a signed request. `invitationProof` is added only to enrollment requests.
    public static func signRequest(method: String, path: String, body: Data, signer: MessageSigner,
                                   now: Date = Date(), nonce: String = newNonce(),
                                   invitation: (id: String, secret: String)? = nil) throws -> [String: String] {
        let ts = Int64(now.timeIntervalSince1970)
        let input = RequestSigningInput(method: method, path: path, timestamp: ts, nonce: nonce,
                                        keyFingerprint: signer.fingerprint, body: body)
        var headers: [String: String] = [
            OriginHeader.protocolVersion: OriginProtocol.version,
            OriginHeader.keyFingerprint: signer.fingerprint,
            OriginHeader.timestamp: String(ts),
            OriginHeader.nonce: nonce,
            OriginHeader.signature: Encoding.base64url(try signer.sign(input.bytes)),
        ]
        if let invitation {
            headers[OriginHeader.invitationProof] = InvitationCode.proof(
                secret: invitation.secret, invitationId: invitation.id, signingInput: input.bytes)
        }
        return headers
    }

    public static func signResponse(status: Int, body: Data, requestNonce: String, signer: MessageSigner,
                                    now: Date = Date()) throws -> [String: String] {
        let ts = Int64(now.timeIntervalSince1970)
        let input = ResponseSigningInput(status: status, requestNonce: requestNonce, timestamp: ts,
                                         keyFingerprint: signer.fingerprint, body: body)
        return [
            OriginHeader.protocolVersion: OriginProtocol.version,
            OriginHeader.keyFingerprint: signer.fingerprint,
            OriginHeader.timestamp: String(ts),
            OriginHeader.requestNonce: requestNonce,
            OriginHeader.publicKey: Encoding.base64url(signer.publicKeyDER),
            OriginHeader.signature: Encoding.base64url(try signer.sign(input.bytes)),
        ]
    }

    /// Parsed, not yet verified, signature headers of a request.
    public struct RequestAuth: Sendable {
        public var keyFingerprint: String
        public var timestamp: Int64
        public var nonce: String
        public var signature: Data
        public var invitationProof: String?
    }

    public static func parseRequestAuth(headers: [String: String]) -> RequestAuth? {
        guard headers[OriginHeader.protocolVersion] == OriginProtocol.version,
              let fp = headers[OriginHeader.keyFingerprint], KeyFingerprint.isValid(fp),
              let tsText = headers[OriginHeader.timestamp], let ts = Int64(tsText),
              let nonce = headers[OriginHeader.nonce], isWellFormedNonce(nonce),
              let sigText = headers[OriginHeader.signature], let sig = Encoding.fromBase64url(sigText) else {
            return nil
        }
        return RequestAuth(keyFingerprint: fp, timestamp: ts, nonce: nonce, signature: sig,
                           invitationProof: headers[OriginHeader.invitationProof])
    }

    /// Verifies a response signature against a pinned key. Returns false on any mismatch.
    public static func verifyResponse(status: Int, headers: [String: String], body: Data, expectedRequestNonce: String,
                                      pinnedFingerprint: String, publicKeyDER: Data, now: Date = Date()) -> Bool {
        guard KeyFingerprint.of(publicKeyDER: publicKeyDER) == pinnedFingerprint,
              headers[OriginHeader.keyFingerprint] == pinnedFingerprint,
              headers[OriginHeader.requestNonce] == expectedRequestNonce,
              let tsText = headers[OriginHeader.timestamp], let ts = Int64(tsText),
              abs(Double(ts) - now.timeIntervalSince1970) <= OriginProtocol.maxClockSkew,
              let sigText = headers[OriginHeader.signature], let sig = Encoding.fromBase64url(sigText) else {
            return false
        }
        let input = ResponseSigningInput(status: status, requestNonce: expectedRequestNonce, timestamp: ts,
                                         keyFingerprint: pinnedFingerprint, body: body)
        return SignatureVerifier.verify(signatureDER: sig, message: input.bytes, publicKeyDER: publicKeyDER)
    }
}

/// Rejects stale and repeated requests. Thread-safe.
public final class ReplayGuard: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable { case fresh, stale, replayed }

    private let lock = NSLock()
    private var seen: [String: Date] = [:]
    private let capacity: Int

    public init(capacity: Int = 20_000) { self.capacity = capacity }

    /// Checks the timestamp window and records the (key, nonce) pair.
    public func check(keyFingerprint: String, nonce: String, timestamp: Int64, now: Date = Date()) -> Verdict {
        if abs(Double(timestamp) - now.timeIntervalSince1970) > OriginProtocol.maxClockSkew { return .stale }
        let key = keyFingerprint + "|" + nonce
        lock.lock(); defer { lock.unlock() }
        if seen.count >= capacity {
            seen = seen.filter { $0.value > now }
            if seen.count >= capacity { return .stale } // fail closed under flooding
        }
        if let until = seen[key], until > now { return .replayed }
        seen[key] = now.addingTimeInterval(OriginProtocol.nonceRetention)
        return .fresh
    }
}

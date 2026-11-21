import Foundation
import HCGOriginProtocol
import HCGHTTP

/// How Connectors reach this gateway.
public enum TransportSecurity: Equatable, Sendable {
    /// TLS 1.3; the Connector pins `fingerprint` (SHA-256 of the certificate's SPKI) from the invitation.
    case tls13Pinned(fingerprint: String, keyStorage: String)
    /// Cleartext HTTP on 127.0.0.1 only. Used by Linux development tests; the macOS app never offers it.
    case cleartextLoopbackDevelopment

    public var invitationTransport: String {
        switch self {
        case .tls13Pinned: return InvitationTransport.tls13Pinned
        case .cleartextLoopbackDevelopment: return InvitationTransport.cleartextLoopbackDevelopment
        }
    }

    public var tlsFingerprint: String? {
        if case .tls13Pinned(let fp, _) = self { return fp }
        return nil
    }

    public var isEncrypted: Bool { tlsFingerprint != nil }
}

/// Creates the Connector-facing listener. The app uses `tls(label:)`; Linux tests use `cleartextLoopback`.
public struct ConnectorTransportFactory: Sendable {
    public let make: @Sendable (_ port: UInt16, _ loopbackOnly: Bool, _ handler: @escaping HTTPServer.Handler) throws -> (ConnectorServer, TransportSecurity)

    public init(make: @escaping @Sendable (UInt16, Bool, @escaping HTTPServer.Handler) throws -> (ConnectorServer, TransportSecurity)) {
        self.make = make
    }

    /// Development only. Refuses anything but loopback.
    public static let cleartextLoopback = ConnectorTransportFactory { port, loopbackOnly, handler in
        guard loopbackOnly else {
            throw TransportError.encryptionRequired
        }
        return (HTTPServer(host: "127.0.0.1", port: port, handler: handler), .cleartextLoopbackDevelopment)
    }

    #if os(macOS)
    /// TLS 1.3 with the gateway's transport certificate from the login Keychain (created on first use).
    public static func tls(label: String) -> ConnectorTransportFactory {
        ConnectorTransportFactory { port, loopbackOnly, handler in
            let identity = try GatewayTLSIdentity.loadOrCreate(label: label)
            let server = TLSHTTPServer(identity: identity.identity, port: port, loopbackOnly: loopbackOnly, handler: handler)
            server.onConnectionFailure = { remote, reason in
                OriginLog.error("TLS connection from \(remote) failed: \(reason)")
                TransportDiagnostics.shared.record(remote: remote, reason: reason)
            }
            return (server, .tls13Pinned(fingerprint: identity.fingerprint, keyStorage: "P-256 key in the macOS login Keychain (\(label))"))
        }
    }
    #endif
}

/// Recent transport failures (TLS handshake errors), surfaced in Activity by the engine.
public final class TransportDiagnostics: @unchecked Sendable {
    public static let shared = TransportDiagnostics()
    private let lock = NSLock()
    private var pending: [(remote: String, reason: String)] = []
    public func record(remote: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        if pending.count < 50 { pending.append((remote, reason)) }
    }
    public func drain() -> [(remote: String, reason: String)] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll()
        return out
    }
}

public enum TransportError: Error, CustomStringConvertible, Equatable {
    case encryptionRequired
    case keychain(String)
    public var description: String {
        switch self {
        case .encryptionRequired:
            return "Accepting devices on the local network requires the encrypted transport (TLS 1.3), which is not available here. Origin does not fall back to cleartext."
        case .keychain(let s): return "The gateway's TLS certificate could not be prepared: \(s)"
        }
    }
}

#if os(macOS)
import Security
import CryptoKit

/// The gateway's TLS certificate and private key in the login Keychain.
///
/// Network.framework needs a `SecIdentity`, which macOS forms from a certificate and a
/// private key held in a keychain. The TLS key is a software P-256 key (the Secure
/// Enclave key that signs gateway messages cannot back a TLS identity without
/// entitlements an ad-hoc build does not have). The certificate is self-signed and valid
/// for ten years; Connectors pin its key, not a certificate authority.
public struct GatewayTLSIdentity {
    public let identity: SecIdentity
    public let certificateDER: Data
    public let fingerprint: String
    public let label: String

    static func tag(_ label: String) -> Data { Data("com.hakmicapitalgroup.hcgorigin.tls|\(label)".utf8) }

    public static func loadOrCreate(label: String) throws -> GatewayTLSIdentity {
        if let existing = try find(label: label) { return existing }
        delete(label: label) // remove any half-created key or certificate
        return try create(label: label)
    }

    /// Finds the identity whose certificate subject is exactly `label`. Keychain label queries are not relied
    /// on for exactness: an identity is used only if its own certificate names this label.
    static func find(label: String) throws -> GatewayTLSIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let refs = out as? [AnyObject] else {
            throw TransportError.keychain("lookup failed (\(message(status)))")
        }
        for ref in refs where CFGetTypeID(ref) == SecIdentityGetTypeID() {
            let identity = ref as! SecIdentity
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
                  (SecCertificateCopySubjectSummary(cert) as String?) == label,
                  let fp = fingerprint(of: cert) else { continue }
            return GatewayTLSIdentity(identity: identity, certificateDER: SecCertificateCopyData(cert) as Data,
                                      fingerprint: fp, label: label)
        }
        return nil
    }

    static func create(label: String) throws -> GatewayTLSIdentity {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(label),
                kSecAttrLabel as String: label,
            ] as [String: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw TransportError.keychain("key creation failed (\(error.map { "\($0.takeRetainedValue())" } ?? "unknown"))")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let spki = try? P256.Signing.PublicKey(x963Representation: raw).derRepresentation else {
            throw TransportError.keychain("public key export failed")
        }
        let certDER: Data
        do {
            certDER = try X509SelfSigned.make(
                spkiDER: spki, commonName: label, serial: Encoding.randomBytes(16),
                notBefore: Date().addingTimeInterval(-86_400), notAfter: Date().addingTimeInterval(10 * 365 * 86_400)) { tbs in
                    var e: Unmanaged<CFError>?
                    guard let sig = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &e) as Data? else {
                        throw TransportError.keychain("certificate signing failed")
                    }
                    return sig
                }
        }
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw TransportError.keychain("certificate encoding was rejected")
        }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert,
                                  kSecAttrLabel as String: label]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TransportError.keychain("certificate could not be stored (\(message(status)))")
        }
        var identity: SecIdentity?
        let s2 = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard s2 == errSecSuccess, let identity else {
            throw TransportError.keychain("certificate and key could not be paired (\(message(s2)))")
        }
        return GatewayTLSIdentity(identity: identity, certificateDER: certDER,
                                  fingerprint: KeyFingerprint.of(publicKeyDER: spki), label: label)
    }

    /// Removes the certificate and private key with this label (used for re-creation and by tests).
    public static func delete(label: String) {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(label)] as CFDictionary)
    }

    static func fingerprint(of cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert), let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let spki = try? P256.Signing.PublicKey(x963Representation: raw).derRepresentation else { return nil }
        return KeyFingerprint.of(publicKeyDER: spki)
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }

    /// Label for a Keychain service name, e.g. "HCG Origin TLS (HCG Origin)".
    public static func label(forService service: String) -> String { "HCG Origin TLS (\(service))" }
}
#endif

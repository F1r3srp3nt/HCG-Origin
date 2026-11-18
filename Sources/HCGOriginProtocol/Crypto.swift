// Cryptography used by the HCG Origin protocol. Standard primitives only:
// ECDSA P-256 / SHA-256 signatures, HMAC-SHA256, HKDF-SHA256. No custom crypto.
#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif
import Foundation

public enum Encoding {
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard s.range(of: "^[A-Za-z0-9+/]*$", options: .regularExpression) != nil else { return nil }
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// Random identifier such as `inv_3f9a…` (72 bits of randomness, hex).
    public static func randomID(prefix: String) -> String {
        prefix + hex(randomBytes(9))
    }
}

/// Something that can produce ECDSA P-256 / SHA-256 signatures (DER encoded).
/// Implemented by software keys and, in the macOS app, Secure Enclave keys.
public protocol MessageSigner: Sendable {
    /// SubjectPublicKeyInfo (DER) of the signing key.
    var publicKeyDER: Data { get }
    func sign(_ message: Data) throws -> Data
}

extension MessageSigner {
    /// SHA-256 of the SubjectPublicKeyInfo, lowercase hex (same definition as HCG Server Device Link).
    public var fingerprint: String { KeyFingerprint.of(publicKeyDER: publicKeyDER) }
}

public struct SoftwareSigner: MessageSigner, @unchecked Sendable {
    public let privateKey: P256.Signing.PrivateKey
    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.privateKey = privateKey }
    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }
    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicKeyDER: Data { privateKey.publicKey.derRepresentation }
    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).derRepresentation
    }
}

public enum KeyFingerprint {
    public static func of(publicKeyDER: Data) -> String { Encoding.sha256Hex(publicKeyDER) }

    /// Short, human-comparable form: first 16 hex digits in groups of four.
    public static func short(_ fingerprint: String) -> String {
        let p = Array(fingerprint.prefix(16))
        return stride(from: 0, to: p.count, by: 4).map { String(p[$0..<min($0 + 4, p.count)]) }.joined(separator: " ")
    }

    public static func isValid(_ fingerprint: String) -> Bool {
        fingerprint.count == 64 && fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

public enum SignatureVerifier {
    /// Verifies a DER ECDSA P-256 signature over `message` with a DER SPKI public key.
    public static func verify(signatureDER: Data, message: Data, publicKeyDER: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signatureDER) else { return false }
        return key.isValidSignature(sig, for: message)
    }

    public static func isValidPublicKey(_ der: Data) -> Bool {
        (try? P256.Signing.PublicKey(derRepresentation: der)) != nil
    }
}

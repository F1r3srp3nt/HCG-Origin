import Foundation
import HCGOriginProtocol
#if canImport(Security)
import Security
#endif

/// Where Origin keeps secrets (gateway key, session tokens). Never logged.
public protocol SecretStore: Sendable {
    var kindDescription: String { get }
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ value: Data) throws
    func delete(_ name: String) throws
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(status: Int32, operation: String)
    case io(String)

    public var description: String {
        switch self {
        case .keychain(let status, let op):
            #if canImport(Security)
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
            #else
            let msg = "status \(status)"
            #endif
            return "Keychain \(op) failed: \(msg)"
        case .io(let s): return s
        }
    }
}

#if canImport(Security) && os(macOS)
/// macOS login Keychain (generic password items, service "HCG Origin").
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "HCG Origin") { self.service = service }
    public var kindDescription: String { "macOS login Keychain" }

    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    public func read(_ name: String) throws -> Data? {
        var q = base(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status, operation: "read") }
        return out as? Data
    }

    public func write(_ name: String, _ value: Data) throws {
        let update = [kSecValueData as String: value]
        var status = SecItemUpdate(base(name) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(name)
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "\(service): \(name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status, operation: "write") }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(base(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status, operation: "delete")
        }
    }
}
#endif

/// DEVELOPMENT/TEST ONLY: secrets in a 0600 file. Used by tests, Linux checks and
/// the Connector test client. Never the default for the macOS app.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    public var kindDescription: String { "development file store (not the Keychain)" }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func save(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func read(_ name: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[name].flatMap { Data(base64Encoded: $0) }
    }

    public func write(_ name: String, _ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        var d = load(); d[name] = value.base64EncodedString(); try save(d)
    }

    public func delete(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var d = load(); d[name] = nil; try save(d)
    }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public var kindDescription: String { "in-memory store (tests)" }
    public func read(_ name: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[name] }
    public func write(_ name: String, _ value: Data) throws { lock.lock(); defer { lock.unlock() }; items[name] = value }
    public func delete(_ name: String) throws { lock.lock(); defer { lock.unlock() }; items[name] = nil }
}

/// The gateway's long-lived identity key.
public struct GatewayIdentity: Sendable {
    public let signer: MessageSigner
    public let keyStorage: String
    public var fingerprint: String { signer.fingerprint }
    public var publicKeyBase64url: String { Encoding.base64url(signer.publicKeyDER) }
    /// Proposed, locally derived identifier. Central issues the real gateway ID.
    public var proposedGatewayId: String { "origin-gw-" + String(fingerprint.prefix(16)) }

    static let softwareKeyName = "gateway-signing-key.p256"
    static let enclaveKeyName = "gateway-signing-key.secure-enclave"

    public enum IdentityError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case .unreadable(let s): return "The gateway identity key could not be loaded: \(s)" }
        }
    }

    /// Loads the existing key or creates one. On Apple silicon the key is created in the
    /// Secure Enclave (the Keychain holds only its wrapped reference); otherwise a P-256
    /// software key is kept in the secret store.
    public static func loadOrCreate(store: SecretStore, preferSecureEnclave: Bool = true) throws -> GatewayIdentity {
        #if canImport(CryptoKit) && os(macOS)
        if let blob = try store.read(enclaveKeyName) {
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
                return GatewayIdentity(signer: SecureEnclaveSigner(key: key), keyStorage: "Secure Enclave (reference in \(store.kindDescription))")
            } catch {
                throw IdentityError.unreadable("Secure Enclave key reference is not usable on this Mac (\(error)). It is not replaced automatically, because a new key would be a new gateway identity.")
            }
        }
        #endif
        if let raw = try store.read(softwareKeyName) {
            do {
                return GatewayIdentity(signer: try SoftwareSigner(rawRepresentation: raw), keyStorage: "P-256 software key in \(store.kindDescription)")
            } catch {
                throw IdentityError.unreadable("stored key is corrupted (\(error))")
            }
        }
        #if canImport(CryptoKit) && os(macOS)
        if preferSecureEnclave && SecureEnclave.isAvailable {
            if let key = try? SecureEnclave.P256.Signing.PrivateKey() {
                try store.write(enclaveKeyName, key.dataRepresentation)
                return GatewayIdentity(signer: SecureEnclaveSigner(key: key), keyStorage: "Secure Enclave (reference in \(store.kindDescription))")
            }
        }
        #endif
        let signer = SoftwareSigner()
        try store.write(softwareKeyName, signer.rawRepresentation)
        return GatewayIdentity(signer: signer, keyStorage: "P-256 software key in \(store.kindDescription)")
    }
}

#if canImport(CryptoKit) && os(macOS)
public struct SecureEnclaveSigner: MessageSigner, @unchecked Sendable {
    let key: SecureEnclave.P256.Signing.PrivateKey
    public var publicKeyDER: Data { key.publicKey.derRepresentation }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}
#endif

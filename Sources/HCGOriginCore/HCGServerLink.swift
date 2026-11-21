import Foundation
import HCGOriginProtocol
import HCGHTTP
#if canImport(Security)
import Security
#endif

// HCG Origin ↔ HCG Server.
//
// HCG Server (Device Link, `hcg.devicelink/1`) is where devices pair: it verifies the device's signed
// request, the person's HCG Connect token and the ERP permission before a pairing request even exists.
// Origin is the owner's console for it on this Mac: it reads pending pairings and installations from
// HCG Server's loopback owner API and performs owner decisions there — always after an explicit local
// review, a central permission check and with the decision attributed to the signed-in owner.
// Origin adds no protocol of its own here and never sends anything that could execute on a device.

/// HCG Server's owner (admin) API: loopback HTTP with the agent's bearer token (HCG Server SECURITY.md).
public struct HCGServerConnection: Codable, Equatable, Sendable {
    /// e.g. http://127.0.0.1:7600 (no path, no token).
    public var adminURL: String
    /// "runtime.json" when discovered on this Mac, "manual" when pasted by the owner.
    public var source: String
}

public enum HCGServerError: Error, CustomStringConvertible, Equatable {
    case notLoopback(String)
    case unreachable(String)
    case unauthorized
    case rejected(status: Int, code: String, message: String)
    case malformed(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .notLoopback(let u): return "HCG Server's owner API must be on this Mac (127.0.0.1); refusing \(u)."
        case .unreachable(let d): return "HCG Server is not reachable (\(d))."
        case .unauthorized: return "HCG Server did not accept the owner token. Reconnect HCG Server in Settings."
        case .rejected(let s, let c, let m): return "HCG Server answered \(s) \(c): \(m)"
        case .malformed(let m): return "Unexpected answer from HCG Server: \(m)"
        case .notFound(let m): return m
        }
    }
}

// MARK: Wire types (subset of HCG Server contracts/v1, decoded tolerantly)

public struct HCGServerHealth: Codable, Equatable, Sendable {
    public var agentVersion: String?
    public var apiVersion: String?
    public var status: String
}

public struct HCGServerDeviceInfo: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var fingerprint: String
    public var platform: String?
    public var agentVersion: String?
}

public struct HCGServerDevice: Codable, Equatable, Sendable {
    public var device: HCGServerDeviceInfo
}

public struct LinkStatusInfo: Codable, Equatable, Sendable {
    public var `protocol`: String?
    public var configured: Bool?
    public var configError: String?
    public var trustedApps: [String]?
    public var mappedPermissions: [String]?
    public var missingPermissions: [String]?
    public var actionsEnabled: Bool?
    public var reachability: String?
}

public struct LinkAccountInfo: Codable, Equatable, Sendable {
    public var subject: String
    public var email: String?
}

public struct LinkOrganisationInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
}

public struct LinkCapabilityInfo: Codable, Equatable, Sendable {
    public var id: String
    public var state: String
    public var reason: String?
}

public struct LinkInstallationDescriptor: Codable, Equatable, Sendable {
    public var installationId: String
    public var name: String
    public var platform: String
    public var app: String
    public var appVersion: String
    public var variant: String?
    public var capabilities: [LinkCapabilityInfo]?
}

public struct LinkPairingInfo: Codable, Equatable, Sendable, Identifiable {
    public var requestId: String
    public var invitationId: String
    public var installation: LinkInstallationDescriptor
    public var keyFingerprint: String
    public var account: LinkAccountInfo
    public var organisation: LinkOrganisationInfo?
    public var observedFrom: String
    public var receivedAt: Date
    public var expiresAt: Date
    public var status: String
    public var decidedAt: Date?
    public var id: String { requestId }
}

public struct LinkInstallationInfo: Codable, Equatable, Sendable, Identifiable {
    public var installationId: String
    public var name: String
    public var platform: String
    public var app: String
    public var appVersion: String
    public var variant: String?
    public var keyFingerprint: String
    public var capabilities: [LinkCapabilityInfo]?
    public var account: LinkAccountInfo
    public var organisation: LinkOrganisationInfo?
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var state: String // online | offline | never-seen | revoked
    public var revokedAt: Date?
    public var revokedBy: String?
    public var id: String { installationId }
}

public struct HCGServerInvitation: Codable, Equatable, Sendable {
    public var id: String
    public var code: String?
    public var expiresAt: Date
    public var status: String
}

/// Owner API client. Loopback only, bearer token, no redirects, never logs the token.
public final class HCGServerAdminClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let http = HTTPClient(timeout: 6)

    public init(adminURL: String, token: String) throws {
        guard let url = URL(string: adminURL), url.scheme == "http" || url.scheme == "https", HTTPClient.isLoopback(url) else {
            throw HCGServerError.notLoopback(adminURL)
        }
        self.baseURL = url
        self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Go encodes time.Time as RFC 3339 with optional fractional seconds.
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            let f2 = ISO8601DateFormatter()
            if let d = f2.date(from: s) { return d }
            // Nanosecond precision: trim to milliseconds.
            if let dot = s.firstIndex(of: "."), let end = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), end > dot {
                let frac = s[s.index(after: dot)..<end].prefix(3)
                if let d = f1.date(from: String(s[..<dot]) + "." + frac + s[end...]) { return d }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, as: T.Type) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw HCGServerError.malformed("bad path \(path)")
        }
        let r: HTTPClientResponse
        do {
            r = try await http.send(method: method, url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"], body: body)
        } catch let e as HTTPClientError {
            throw HCGServerError.unreachable(e.description)
        }
        if r.status == 401 { throw HCGServerError.unauthorized }
        guard (200..<300).contains(r.status) else {
            let e = try? JSONDecoder().decode(ServerErrorBody.self, from: r.body)
            throw HCGServerError.rejected(status: r.status, code: e?.code ?? "http_\(r.status)", message: e?.error ?? "")
        }
        do { return try Self.decoder.decode(T.self, from: r.body) }
        catch { throw HCGServerError.malformed("\(T.self): \(error)") }
    }

    struct ServerErrorBody: Decodable { var error: String?; var code: String? }
    struct Empty: Decodable {}
    struct Status: Decodable { var status: String }

    public func health() async throws -> HCGServerHealth { try await call("GET", "/healthz", as: HCGServerHealth.self) }
    public func device() async throws -> HCGServerDevice { try await call("GET", "/api/v1/device", as: HCGServerDevice.self) }
    public func linkStatus() async throws -> LinkStatusInfo { try await call("GET", "/api/v1/link/status", as: LinkStatusInfo.self) }
    public func pairings() async throws -> [LinkPairingInfo] { try await call("GET", "/api/v1/link/pairings", as: [LinkPairingInfo].self) }
    public func installations() async throws -> [LinkInstallationInfo] { try await call("GET", "/api/v1/link/installations", as: [LinkInstallationInfo].self) }

    public func approve(requestId: String) async throws -> LinkInstallationInfo {
        try await call("POST", "/api/v1/link/pairings/\(requestId)/approve", body: Data("{}".utf8), as: LinkInstallationInfo.self)
    }
    public func reject(requestId: String) async throws {
        _ = try await call("POST", "/api/v1/link/pairings/\(requestId)/reject", body: Data("{}".utf8), as: Status.self)
    }
    public func revoke(installationId: String) async throws {
        _ = try await call("POST", "/api/v1/link/installations/\(installationId)/revoke", body: Data("{}".utf8), as: Status.self)
    }
    public func createInvitation(ttlSeconds: Int) async throws -> HCGServerInvitation {
        try await call("POST", "/api/v1/pairing/invitations", body: Data("{\"ttlSeconds\":\(ttlSeconds)}".utf8), as: HCGServerInvitation.self)
    }
}

/// Finds HCG Server on this Mac. Reads only HCG Server's public runtime file; the owner token is read from
/// the Keychain only when the owner explicitly connects (macOS asks for permission).
public enum HCGServerLocator {
    public static func defaultDataDirectory() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HCG Server/agent", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/hcg-server/agent", isDirectory: true)
        #endif
    }

    public struct Runtime: Decodable, Equatable { public var adminAddress: String; public var peerAddress: String?; public var pid: Int32? }

    public static func runtime(dataDirectory: URL = defaultDataDirectory()) -> Runtime? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("runtime.json")) else { return nil }
        return try? HCGServerAdminClient.decoder.decode(Runtime.self, from: data)
    }

    /// HCG Server's Keychain account for the owner token: "<first 12 hex of SHA-256(absolute data dir)>/admin-token".
    public static func tokenAccount(dataDirectory: URL) -> String {
        let abs = dataDirectory.standardizedFileURL.path
        return String(Encoding.sha256Hex(Data(abs.utf8)).prefix(12)) + "/admin-token"
    }

    #if canImport(Security) && os(macOS)
    /// Reads HCG Server's owner token from the login Keychain (service "HCG Server Agent"). macOS shows a
    /// permission prompt naming HCG Origin; nothing is read unless the owner allows it.
    public static func keychainToken(dataDirectory: URL = defaultDataDirectory()) throws -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "HCG Server Agent",
                                kSecAttrAccount as String: tokenAccount(dataDirectory: dataDirectory),
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let token = String(data: data, encoding: .utf8) else {
            throw HCGServerError.notFound("HCG Server's owner token is not available in the Keychain (status \(status)). Start HCG Server once, or paste the link from `hcg-agent admin-url`.")
        }
        return token
    }
    #endif

    /// Parses the link printed by `hcg-agent admin-url`: http://127.0.0.1:7600/#token=…
    public static func parseAdminLink(_ text: String) -> (adminURL: String, token: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = t.range(of: "#token="), let base = URL(string: String(t[..<hash.lowerBound])), HTTPClient.isLoopback(base),
              let token = String(t[hash.upperBound...]).removingPercentEncoding, token.count >= 16 else { return nil }
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return (s, token)
    }
}

public enum HCGServerReachability: Equatable, Sendable {
    case notConnected
    case reachable(at: Date)
    case unreachable(String, since: Date)
    case unauthorized
}

/// What Origin knows about HCG Server, for the UI.
public struct HCGServerSnapshot: Equatable, Sendable {
    public var connection: HCGServerConnection?
    public var reachability: HCGServerReachability
    public var health: HCGServerHealth?
    public var device: HCGServerDeviceInfo?
    public var link: LinkStatusInfo?
    public var pairings: [LinkPairingInfo]
    public var installations: [LinkInstallationInfo]
    public var lastSyncAt: Date?
    public var lastError: String?
    public var lastInvitation: HCGServerInvitation?

    public static let empty = HCGServerSnapshot(connection: nil, reachability: .notConnected, health: nil, device: nil, link: nil,
                                                pairings: [], installations: [], lastSyncAt: nil, lastError: nil, lastInvitation: nil)
    public var pendingPairings: [LinkPairingInfo] { pairings.filter { $0.status == "pending" } }
}

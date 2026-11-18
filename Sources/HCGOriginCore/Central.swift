import Foundation
import HCGOriginProtocol
import HCGHTTP

/// Production integration values. They come only from the app's Info.plist (or an
/// explicit configuration file) and are all empty in this build: none has been issued.
/// Until every value is present, production enrollment is unavailable.
public struct ProductionConfiguration: Codable, Equatable, Sendable {
    public var hcgConnectIssuer: String
    public var hcgConnectClientID: String
    public var hcgConnectRedirectURI: String
    public var centralOriginAPIBase: String

    public static let infoPlistKeys = (
        issuer: "HCGConnectIssuer", clientID: "HCGConnectClientID",
        redirectURI: "HCGConnectRedirectURI", centralBase: "HCGCentralOriginAPIBase"
    )

    public init(hcgConnectIssuer: String = "", hcgConnectClientID: String = "", hcgConnectRedirectURI: String = "", centralOriginAPIBase: String = "") {
        self.hcgConnectIssuer = hcgConnectIssuer; self.hcgConnectClientID = hcgConnectClientID
        self.hcgConnectRedirectURI = hcgConnectRedirectURI; self.centralOriginAPIBase = centralOriginAPIBase
    }

    public static func fromInfoDictionary(_ info: [String: Any]?) -> ProductionConfiguration {
        func v(_ k: String) -> String { ((info?[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let k = infoPlistKeys
        return ProductionConfiguration(hcgConnectIssuer: v(k.issuer), hcgConnectClientID: v(k.clientID),
                                       hcgConnectRedirectURI: v(k.redirectURI), centralOriginAPIBase: v(k.centralBase))
    }

    /// Human-readable list of what is missing or invalid. Empty means complete.
    public var problems: [String] {
        var p: [String] = []
        if hcgConnectClientID.isEmpty { p.append("HCG Connect client ID for HCG Origin (not issued — ERP → App Integrations)") }
        if hcgConnectRedirectURI.isEmpty { p.append("HCG Connect redirect URI for HCG Origin (proposed, not registered)") }
        if hcgConnectIssuer.isEmpty { p.append("HCG Connect issuer (from HCG discovery)") }
        else if URL(string: hcgConnectIssuer)?.scheme != "https" { p.append("HCG Connect issuer must be an https URL") }
        if centralOriginAPIBase.isEmpty { p.append("Central HCG Origin API base URL (endpoints not implemented by main HCG yet)") }
        else if URL(string: centralOriginAPIBase)?.scheme != "https" { p.append("Central HCG Origin API base must be an https URL") }
        return p
    }

    public var isComplete: Bool { problems.isEmpty }
}

public enum CentralError: Error, CustomStringConvertible, Equatable {
    case notConfigured([String])
    case signedOut
    case unreachable(String)
    case unauthorized(String)
    case rejected(status: Int, code: String, message: String)
    case malformed(String)
    case environmentMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .notConfigured(let m): return "Production HCG is not configured: " + m.joined(separator: "; ")
        case .signedOut: return "Not signed in."
        case .unreachable(let d): return "Central service unreachable (\(d))."
        case .unauthorized(let m): return "Central service refused the sign-in: \(m)"
        case .rejected(let s, let c, let m): return "Central service answered \(s) \(c): \(m)"
        case .malformed(let m): return "Central service sent an unexpected response: \(m)"
        case .environmentMismatch(let e, let a):
            return "The configured central service reports environment '\(a)', but Origin expected '\(e)'. Nothing was sent."
        }
    }

    public var isTransient: Bool {
        switch self {
        case .unreachable: return true
        case .rejected(let s, _, _): return s >= 500 || s == 429
        default: return false
        }
    }
}

/// Origin's client for the (proposed) central HCG Origin API.
public protocol CentralService: Sendable {
    var mode: CentralMode { get }
    var baseURL: URL { get }
    func health() async throws -> CentralHealth
    func account(token: String) async throws -> CentralAccount
    func registerGateway(_ request: GatewayRegistrationRequest, token: String) async throws -> GatewayRegistration
    func submitEnrollment(_ submission: CentralEnrollmentSubmission, token: String) async throws -> CentralEnrollmentRecord
    func enrollment(id: String, token: String) async throws -> CentralEnrollmentRecord
    func devices(gatewayId: String, token: String) async throws -> CentralDeviceList
    func report(events: [GatewayEvent], gatewayId: String, token: String) async throws
}

public final class HTTPCentralService: CentralService, @unchecked Sendable {
    public let mode: CentralMode
    public let baseURL: URL
    let signer: MessageSigner
    let client: HTTPClient

    public init(mode: CentralMode, baseURL: URL, signer: MessageSigner, timeout: TimeInterval = 8) {
        self.mode = mode
        self.baseURL = baseURL
        self.signer = signer
        self.client = HTTPClient(timeout: timeout)
    }

    private func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    private func call<T: Decodable>(_ method: String, _ path: String, token: String?, body: Data?, as: T.Type) async throws -> T {
        let target = url(path)
        do { try HTTPClient.checkTransport(target) } catch { throw CentralError.malformed("\(error)") }
        let payload = body ?? Data()
        var headers = try SignedEnvelope.signRequest(method: method, path: target.path, body: payload, signer: signer)
        headers["Accept"] = "application/json"
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let response: HTTPClientResponse
        do {
            response = try await client.send(method: method, url: target, headers: headers, body: body)
        } catch let e as HTTPClientError {
            throw CentralError.unreachable(e.description)
        }
        if (200..<300).contains(response.status) {
            do { return try Wire.decoder().decode(T.self, from: response.body) }
            catch { throw CentralError.malformed("\(T.self): \(error)") }
        }
        let err = try? Wire.decoder().decode(ErrorBody.self, from: response.body)
        if response.status == 401 { throw CentralError.unauthorized(err?.error.message ?? "session not accepted") }
        throw CentralError.rejected(status: response.status, code: err?.error.code ?? "http_\(response.status)",
                                    message: err?.error.message ?? "no details")
    }

    private struct Accepted: Decodable { var accepted: Int }

    public func health() async throws -> CentralHealth {
        let h = try await call("GET", CentralPath.health, token: nil, body: nil, as: CentralHealth.self)
        guard h.environment == mode.wireEnvironment else {
            throw CentralError.environmentMismatch(expected: mode.wireEnvironment, actual: h.environment)
        }
        return h
    }
    public func account(token: String) async throws -> CentralAccount {
        try await call("GET", CentralPath.account, token: token, body: nil, as: CentralAccount.self)
    }
    public func registerGateway(_ request: GatewayRegistrationRequest, token: String) async throws -> GatewayRegistration {
        try await call("POST", CentralPath.gateways, token: token, body: Wire.encode(request), as: GatewayRegistration.self)
    }
    public func submitEnrollment(_ submission: CentralEnrollmentSubmission, token: String) async throws -> CentralEnrollmentRecord {
        try await call("POST", CentralPath.enrollments, token: token, body: Wire.encode(submission), as: CentralEnrollmentRecord.self)
    }
    public func enrollment(id: String, token: String) async throws -> CentralEnrollmentRecord {
        try await call("GET", CentralPath.enrollment(id), token: token, body: nil, as: CentralEnrollmentRecord.self)
    }
    public func devices(gatewayId: String, token: String) async throws -> CentralDeviceList {
        try await call("GET", CentralPath.gatewayDevices(gatewayId), token: token, body: nil, as: CentralDeviceList.self)
    }
    public func report(events: [GatewayEvent], gatewayId: String, token: String) async throws {
        _ = try await call("POST", CentralPath.gatewayEvents(gatewayId), token: token,
                           body: Wire.encode(GatewayEventBatch(events: events)), as: Accepted.self)
    }
}

/// Development-only sign-in against the local development service. This is NOT HCG
/// Connect: it proves nothing about a real HCG account.
public enum DevelopmentSignIn {
    public struct Request: Codable { public var email: String; public var displayName: String }
    public struct Response: Codable { public var accessToken: String; public var account: CentralAccount }

    /// `{scheme}://{host}:{port}/dev/v1/sign-in` derived from the development service URL.
    public static func signInURL(forServiceURL url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/dev/v1/sign-in"
        c.query = nil
        return c.url
    }

    public static func signIn(serviceURL: URL, email: String, displayName: String) async throws -> Response {
        guard HTTPClient.isLoopback(serviceURL) else {
            throw CentralError.malformed("The development service must run on this computer (127.0.0.1).")
        }
        guard let target = signInURL(forServiceURL: serviceURL) else { throw CentralError.malformed("bad development service URL") }
        let client = HTTPClient(timeout: 5)
        let r: HTTPClientResponse
        do {
            r = try await client.send(method: "POST", url: target, body: Wire.encode(Request(email: email, displayName: displayName)))
        } catch let e as HTTPClientError {
            throw CentralError.unreachable(e.description)
        }
        guard r.status == 200 else {
            let err = try? Wire.decoder().decode(ErrorBody.self, from: r.body)
            throw CentralError.rejected(status: r.status, code: err?.error.code ?? "http_\(r.status)", message: err?.error.message ?? "")
        }
        do { return try Wire.decoder().decode(Response.self, from: r.body) }
        catch { throw CentralError.malformed("sign-in response: \(error)") }
    }
}

/// HCG Connect (OIDC, public client, Authorization Code + PKCE S256) helpers.
/// Used only when `ProductionConfiguration` is complete, which it is not in this build.
public enum HCGConnectPKCE {
    public struct Discovery: Codable, Equatable, Sendable {
        public var issuer: String
        public var authorization_endpoint: String
        public var token_endpoint: String
        public var code_challenge_methods_supported: [String]?
    }

    public struct Tokens: Codable, Equatable, Sendable {
        public var access_token: String
        public var refresh_token: String?
        public var expires_in: Int?
        public var token_type: String?
    }

    public static func newVerifier() -> String { Encoding.base64url(Encoding.randomBytes(32)) }

    public static func challenge(for verifier: String) -> String {
        Encoding.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func discover(issuer: String) async throws -> Discovery {
        guard let url = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/openid-configuration"),
              url.scheme == "https" else { throw CentralError.malformed("issuer must be https") }
        let r = try await HTTPClient(timeout: 10).send(method: "GET", url: url)
        guard r.status == 200 else { throw CentralError.rejected(status: r.status, code: "discovery_failed", message: "") }
        let d = try JSONDecoder().decode(Discovery.self, from: r.body)
        guard d.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw CentralError.malformed("discovery issuer does not match the configured issuer")
        }
        guard d.code_challenge_methods_supported?.contains("S256") == true else {
            throw CentralError.malformed("issuer does not advertise PKCE S256")
        }
        return d
    }

    public static func authorizeURL(discovery: Discovery, clientID: String, redirectURI: String, state: String, challenge: String) -> URL? {
        guard var c = URLComponents(string: discovery.authorization_endpoint), c.scheme == "https" else { return nil }
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return c.url
    }

    public static func exchange(code: String, verifier: String, discovery: Discovery, clientID: String, redirectURI: String) async throws -> Tokens {
        guard let url = URL(string: discovery.token_endpoint), url.scheme == "https" else { throw CentralError.malformed("token endpoint must be https") }
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let form = "grant_type=authorization_code&code=\(enc(code))&redirect_uri=\(enc(redirectURI))&client_id=\(enc(clientID))&code_verifier=\(enc(verifier))"
        let r = try await HTTPClient(timeout: 15).send(method: "POST", url: url,
                                                      headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                      body: Data(form.utf8))
        guard r.status == 200 else { throw CentralError.unauthorized("token exchange failed (\(r.status))") }
        return try JSONDecoder().decode(Tokens.self, from: r.body)
    }
}

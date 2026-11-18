import Foundation
import HCGOriginProtocol
import HCGHTTP

/// DEVELOPMENT TEST CLIENT for the HCG Origin enrollment protocol.
///
/// This is not the HCG Connector app. It exists to exercise the proposed protocol
/// end to end: it keeps a P-256 device key in a 0600 profile file (the real
/// Connector must use the platform keystore), verifies every gateway response
/// against the fingerprint pinned by the invitation, and never sends the
/// invitation secret (it proves possession with an HMAC).
public final class ConnectorTestClient: @unchecked Sendable {
    public static let clientKind = "connector-test-client"
    public static let version = "0.1.0-test"
    public static let banner = "HCG Connector — DEVELOPMENT TEST CLIENT (not the HCG Connector app)"

    public struct PairedGateway: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var publicKey: String?
        public var name: String
        public var address: String
        public var environment: String
    }

    public struct Profile: Codable, Equatable, Sendable {
        public var privateKey: String // raw P-256, base64url — test client only
        public var proposedDeviceId: String
        public var name: String
        public var gateway: PairedGateway?
        public var requestId: String?
        public var checkCode: String?
        public var deviceId: String?
        public var grant: DeviceGrant?
        public var sequence: Int
    }

    public enum ClientError: Error, CustomStringConvertible, Equatable {
        case invitation(String)
        case gateway(status: Int, code: String, message: String)
        case unverifiedResponse(String)
        case notPaired
        case notEnrolled
        case transport(String)

        public var description: String {
            switch self {
            case .invitation(let s): return s
            case .gateway(let status, let code, let message): return "Gateway answered \(status) \(code): \(message)"
            case .unverifiedResponse(let s): return "Response failed verification and was ignored: \(s)"
            case .notPaired: return "This profile has not sent an enrollment request yet."
            case .notEnrolled: return "This profile is not enrolled (no issued device ID)."
            case .transport(let s): return s
            }
        }

        public var code: String? {
            if case .gateway(_, let code, _) = self { return code }
            return nil
        }
    }

    public let profileURL: URL
    public internal(set) var profile: Profile
    let signer: SoftwareSigner
    let http = HTTPClient(timeout: 10)

    public init(profileDirectory: URL, name: String? = nil) throws {
        profileURL = profileDirectory.appendingPathComponent("profile.json")
        if let data = try? Data(contentsOf: profileURL), let p = try? Wire.decoder().decode(Profile.self, from: data),
           let raw = Encoding.fromBase64url(p.privateKey) {
            profile = p
            signer = try SoftwareSigner(rawRepresentation: raw)
            if let name, name != p.name { profile.name = name }
        } else {
            let s = SoftwareSigner()
            signer = s
            profile = Profile(privateKey: Encoding.base64url(s.rawRepresentation),
                              proposedDeviceId: "dev-" + String(s.fingerprint.prefix(16)),
                              name: name ?? "Connector Test Client", gateway: nil, requestId: nil, checkCode: nil,
                              deviceId: nil, grant: nil, sequence: 0)
        }
        try save()
    }

    public var fingerprint: String { signer.fingerprint }

    func save() throws {
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Wire.encode(profile).write(to: profileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
    }

    public static func platformDescription() -> String {
        #if os(macOS)
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        return "Linux"
        #endif
    }

    public var descriptor: DeviceDescriptor {
        DeviceDescriptor(publicKey: Encoding.base64url(signer.publicKeyDER), proposedDeviceId: profile.proposedDeviceId,
                         name: profile.name, platform: Self.platformDescription(), model: ProcessInfo.processInfo.hostName,
                         softwareVersion: Self.version, clientKind: Self.clientKind)
    }

    // MARK: Low-level (also used by tests to exercise replay and tampering)

    public struct PreparedRequest: Sendable {
        public var url: URL
        public var path: String
        public var body: Data
        public var headers: [String: String]
        public var nonce: String
    }

    public func prepare(path: String, body: Data, address: String, invitation: (id: String, secret: String)? = nil,
                        now: Date = Date()) throws -> PreparedRequest {
        guard let url = URL(string: "http://\(address)\(path)") else { throw ClientError.transport("bad gateway address \(address)") }
        try HTTPClient.checkTransport(url, allowPrivateNetworkHTTP: true)
        let nonce = SignedEnvelope.newNonce()
        let headers = try SignedEnvelope.signRequest(method: "POST", path: path, body: body, signer: signer, now: now,
                                                     nonce: nonce, invitation: invitation)
        return PreparedRequest(url: url, path: path, body: body, headers: headers, nonce: nonce)
    }

    /// Sends a prepared request and verifies the response against the pinned gateway fingerprint.
    public func send(_ request: PreparedRequest, pinnedFingerprint: String) async throws -> HTTPClientResponse {
        let response: HTTPClientResponse
        do {
            response = try await http.send(method: "POST", url: request.url, headers: request.headers, body: request.body)
        } catch {
            throw ClientError.transport("Gateway not reachable at \(request.url.host ?? "?"):\(request.url.port ?? 0) — \(error)")
        }
        guard let keyText = response.headers[OriginHeader.publicKey], let key = Encoding.fromBase64url(keyText) else {
            throw ClientError.unverifiedResponse("unsigned response (HTTP \(response.status))")
        }
        guard SignedEnvelope.verifyResponse(status: response.status, headers: response.headers, body: response.body,
                                            expectedRequestNonce: request.nonce, pinnedFingerprint: pinnedFingerprint,
                                            publicKeyDER: key) else {
            throw ClientError.unverifiedResponse("signature does not match the gateway pinned by the invitation")
        }
        return response
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: HTTPClientResponse) throws -> T {
        guard (200..<300).contains(response.status) else {
            let e = try? Wire.decoder().decode(ErrorBody.self, from: response.body)
            throw ClientError.gateway(status: response.status, code: e?.error.code ?? "http_\(response.status)",
                                      message: e?.error.message ?? "")
        }
        do { return try Wire.decoder().decode(T.self, from: response.body) }
        catch { throw ClientError.unverifiedResponse("malformed \(T.self)") }
    }

    // MARK: Protocol steps

    public func enroll(code: String, capabilities: [String]) async throws -> EnrollResponseBody {
        let invitation: InvitationPayload
        do {
            invitation = try InvitationCode.decode(code)
            try InvitationCode.validate(invitation)
        } catch let e as InvitationError {
            throw ClientError.invitation(e.description)
        }
        let body = Wire.encode(EnrollRequestBody(invitationId: invitation.invitationId, gatewayFingerprint: invitation.gatewayFingerprint,
                                                 device: descriptor, requestedCapabilities: capabilities))
        let prepared = try prepare(path: OriginPath.enroll, body: body, address: invitation.address,
                                   invitation: (invitation.invitationId, invitation.secret))
        let response = try await send(prepared, pinnedFingerprint: invitation.gatewayFingerprint)
        let result = try decode(EnrollResponseBody.self, response)
        guard result.gatewayFingerprint == invitation.gatewayFingerprint,
              let key = Encoding.fromBase64url(result.gatewayPublicKey),
              KeyFingerprint.of(publicKeyDER: key) == invitation.gatewayFingerprint else {
            throw ClientError.unverifiedResponse("gateway identity in the body does not match the invitation")
        }
        let expectedCheck = PairingCheckCode.compute(gatewayFingerprint: invitation.gatewayFingerprint,
                                                     deviceFingerprint: fingerprint, invitationId: invitation.invitationId)
        guard expectedCheck == result.checkCode else { throw ClientError.unverifiedResponse("check code mismatch") }
        profile.gateway = PairedGateway(fingerprint: invitation.gatewayFingerprint, publicKey: result.gatewayPublicKey,
                                        name: result.gatewayName, address: invitation.address, environment: invitation.environment)
        profile.requestId = result.requestId
        profile.checkCode = result.checkCode
        profile.deviceId = nil
        profile.grant = nil
        try save()
        return result
    }

    public func status() async throws -> EnrollmentStatusResponseBody {
        guard let gw = profile.gateway, let requestId = profile.requestId else { throw ClientError.notPaired }
        let prepared = try prepare(path: OriginPath.enrollmentStatus, body: Wire.encode(EnrollmentStatusRequestBody(requestId: requestId)),
                                   address: gw.address)
        let result = try decode(EnrollmentStatusResponseBody.self, try await send(prepared, pinnedFingerprint: gw.fingerprint))
        if result.state == .approved, let id = result.deviceId {
            profile.deviceId = id
            profile.grant = result.grant
            try save()
        }
        return result
    }

    public func heartbeat(report: DeviceStatusReport? = nil) async throws -> HeartbeatResponseBody {
        guard let gw = profile.gateway else { throw ClientError.notPaired }
        guard let deviceId = profile.deviceId else { throw ClientError.notEnrolled }
        profile.sequence += 1
        try save()
        let prepared = try prepare(path: OriginPath.heartbeat,
                                   body: Wire.encode(HeartbeatRequestBody(deviceId: deviceId, sequence: profile.sequence, report: report)),
                                   address: gw.address)
        let result = try decode(HeartbeatResponseBody.self, try await send(prepared, pinnedFingerprint: gw.fingerprint))
        profile.grant = result.grant
        try save()
        return result
    }

    public func forget() throws {
        try? FileManager.default.removeItem(at: profileURL)
    }

    public static func defaultProfileDirectory(name: String = "default") -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HCG Connector Test Client/\(name)", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/hcg-connector-testclient/\(name)", isDirectory: true)
        #endif
    }

    public static func localStatusReport() -> DeviceStatusReport {
        DeviceStatusReport(osVersion: ProcessInfo.processInfo.operatingSystemVersionString, batteryPercent: nil,
                           uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime))
    }
}

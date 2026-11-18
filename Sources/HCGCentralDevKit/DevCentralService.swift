import Foundation
import HCGOriginProtocol
import HCGHTTP

/// LOCAL DEVELOPMENT SERVICE — a stand-in for central HCG (HCG Connect account checks
/// and ERP admission) that implements the PROPOSED HCG Origin central contract.
///
/// It is not HCG, not ERP and not a security boundary for real devices. Its decisions
/// are made by whoever opens its page on this computer. Every response says
/// `environment: development`, issued identifiers start with `hcgdev_`, and Origin
/// labels everything it learns from here as development-only.
public final class DevCentralService: @unchecked Sendable {
    public static let serviceName = "HCG Origin local development service (not HCG)"
    public static let apiPrefix = "/api/public/origin/v1/"

    struct StoredGateway: Codable {
        var registration: GatewayRegistration
        var publicKey: String
        var name: String
    }

    struct StoredEnrollment: Codable {
        var record: CentralEnrollmentRecord
        var submission: CentralEnrollmentSubmission
        var gatewayId: String
        var ownerAccountId: String
        var createdAt: Date
        var expiresAt: Date
        var checkCode: String
    }

    struct StoredDevice: Codable {
        var record: CentralDeviceRecord
        var gatewayId: String
    }

    struct StoredEvent: Codable {
        var gatewayId: String
        var event: GatewayEvent
        var receivedAt: Date
    }

    struct DecisionLog: Codable {
        var at: Date
        var action: String
        var subject: String
        var detail: String
    }

    struct State: Codable {
        var accounts: [String: CentralAccount] = [:] // keyed by SHA-256 of the token
        var gateways: [String: StoredGateway] = [:]
        var enrollments: [String: StoredEnrollment] = [:]
        var devices: [String: StoredDevice] = [:]
        var events: [StoredEvent] = []
        var log: [DecisionLog] = []
    }

    public let adminToken: String
    let stateURL: URL?
    let clock: @Sendable () -> Date
    let lock = NSLock()
    var state = State()
    var outage = false
    let replay = ReplayGuard()
    var server: HTTPServer?
    public private(set) var port: UInt16
    public var enrollmentTTL: TimeInterval = 30 * 60

    public init(port: UInt16 = 47_800, stateURL: URL? = nil, adminToken: String? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.stateURL = stateURL
        self.adminToken = adminToken ?? Encoding.base64url(Encoding.randomBytes(24))
        self.clock = clock
        if let stateURL, let data = try? Data(contentsOf: stateURL), let s = try? Wire.decoder().decode(State.self, from: data) {
            state = s
        }
    }

    public var rootURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/api/public/origin/v1")! }

    @discardableResult
    public func start() throws -> UInt16 {
        let s = HTTPServer(host: "127.0.0.1", port: port) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503) }
            return self.handle(request)
        }
        port = try s.start()
        server = s
        return port
    }

    public func stop() { server?.stop(); server = nil }

    func save() {
        guard let stateURL else { return }
        let enc = Wire.encoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? enc.encode(state) {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    func note(_ action: String, _ subject: String, _ detail: String) {
        state.log.append(DecisionLog(at: clock(), action: action, subject: subject, detail: detail))
        if state.log.count > 500 { state.log.removeFirst(state.log.count - 500) }
    }

    // MARK: Programmatic controls (tests, CLI)

    public enum ControlError: Error, CustomStringConvertible {
        case notFound(String), invalid(String)
        public var description: String {
            switch self { case .notFound(let s): return "not found: \(s)"; case .invalid(let s): return s }
        }
    }

    public func setOutage(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        outage = enabled
        note("outage", "service", enabled ? "Simulated outage ON" : "Simulated outage OFF")
    }

    public var pendingEnrollmentIds: [String] {
        lock.lock(); defer { lock.unlock() }
        expireLocked()
        return state.enrollments.values.filter { $0.record.state == .pendingReview }.sorted { $0.createdAt < $1.createdAt }.map(\.record.enrollmentId)
    }

    public func enrollmentRecord(_ id: String) -> CentralEnrollmentRecord? {
        lock.lock(); defer { lock.unlock() }
        return state.enrollments[id]?.record
    }

    public func deviceRecords() -> [CentralDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return state.devices.values.map(\.record).sorted { $0.deviceId < $1.deviceId }
    }

    public func receivedEvents() -> [GatewayEvent] {
        lock.lock(); defer { lock.unlock() }
        return state.events.map(\.event)
    }

    public func approve(enrollmentId: String, capabilities: [String]? = nil, note text: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try approveLocked(enrollmentId, capabilities: capabilities, note: text)
    }

    public func reject(enrollmentId: String, reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        try rejectLocked(enrollmentId, reason: reason)
    }

    public func revoke(deviceId: String, reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        try revokeLocked(deviceId, reason: reason)
    }

    func approveLocked(_ id: String, capabilities: [String]?, note text: String?) throws {
        expireLocked()
        guard var e = state.enrollments[id] else { throw ControlError.notFound(id) }
        guard e.record.state == .pendingReview else { throw ControlError.invalid("Enrollment \(id) is \(e.record.state.rawValue), not pending.") }
        let requested = e.submission.requestedCapabilities
        let chosen = capabilities ?? requested
        if let bad = chosen.first(where: { Capability.isExecutionLike($0) }) {
            throw ControlError.invalid("\(bad) cannot be granted through enrollment. Execution needs separate Agent Runtime authorisation.")
        }
        if let extra = chosen.first(where: { !requested.contains($0) }) {
            throw ControlError.invalid("\(extra) was not requested by the device.")
        }
        if let dup = state.devices.values.first(where: { $0.record.fingerprint == e.submission.device.publicKeyFingerprint && $0.record.status == .active && $0.gatewayId == e.gatewayId }) {
            throw ControlError.invalid("This device key is already admitted as \(dup.record.deviceId).")
        }
        let now = clock()
        let deviceId = Encoding.randomID(prefix: "hcgdev_dev_")
        let grant = DeviceGrant(capabilities: chosen.sorted(), executionAuthorized: false, grantedAt: now, decidedBy: "local-development-service")
        e.record.state = .approved
        e.record.decidedAt = now
        e.record.deviceId = deviceId
        e.record.grant = grant
        e.record.reason = text
        state.enrollments[id] = e
        state.devices[deviceId] = StoredDevice(record: CentralDeviceRecord(
            deviceId: deviceId, fingerprint: e.submission.device.publicKeyFingerprint, name: e.submission.device.name,
            status: .active, grant: grant, ownerAccountId: e.ownerAccountId, revokedAt: nil, revocationReason: nil), gatewayId: e.gatewayId)
        note("approve", id, "\(e.submission.device.name) → \(deviceId) with \(grant.capabilities.joined(separator: ", "))")
        save()
    }

    func rejectLocked(_ id: String, reason: String) throws {
        expireLocked()
        guard var e = state.enrollments[id] else { throw ControlError.notFound(id) }
        guard e.record.state == .pendingReview else { throw ControlError.invalid("Enrollment \(id) is \(e.record.state.rawValue), not pending.") }
        e.record.state = .rejected
        e.record.decidedAt = clock()
        e.record.reason = reason.isEmpty ? "Rejected by the development approver." : reason
        state.enrollments[id] = e
        note("reject", id, "\(e.submission.device.name): \(e.record.reason ?? "")")
        save()
    }

    func revokeLocked(_ id: String, reason: String) throws {
        guard var d = state.devices[id] else { throw ControlError.notFound(id) }
        guard d.record.status == .active else { throw ControlError.invalid("\(id) is already revoked.") }
        d.record.status = .revoked
        d.record.revokedAt = clock()
        d.record.revocationReason = reason.isEmpty ? "Revoked by the development approver." : reason
        state.devices[id] = d
        note("revoke", id, "\(d.record.name): \(d.record.revocationReason ?? "")")
        save()
    }

    func expireLocked() {
        let now = clock()
        for (id, e) in state.enrollments where e.record.state == .pendingReview && e.expiresAt <= now {
            state.enrollments[id]?.record.state = .expired
            state.enrollments[id]?.record.reason = "No decision within \(Int(enrollmentTTL / 60)) minutes."
        }
    }

    // MARK: HTTP

    func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse { HTTPResponse.json(status, Wire.encode(value)) }

    func fail(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(status, ErrorBody(code: code, message: message))
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        // DNS-rebinding defence: only loopback host names.
        let host = (request.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard host == "127.0.0.1" || host == "localhost" else {
            return fail(403, "forbidden_host", "The development service answers only on 127.0.0.1.")
        }
        guard request.remoteAddress.hasPrefix("127.") else { return fail(403, "forbidden", "Loopback only.") }
        lock.lock(); defer { lock.unlock() }
        if request.method == "GET" && (request.path == "/" || request.path == "/erp") {
            return HTTPResponse(status: 200, headers: [
                "content-type": "text/html; charset=utf-8",
                "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:",
                "x-frame-options": "DENY", "referrer-policy": "no-referrer",
            ], body: Data(DevERPPage.html(adminToken: adminToken).utf8))
        }
        if request.path.hasPrefix("/dev/v1/admin/") { return handleAdmin(request) }
        if outage { return fail(503, CentralErrorCode.serviceUnavailable, "Simulated outage (local development service).") }
        if request.path == "/dev/v1/sign-in" && request.method == "POST" { return handleSignIn(request) }
        guard request.path.hasPrefix(Self.apiPrefix) else { return fail(404, CentralErrorCode.notFound, "Unknown path.") }
        let sub = String(request.path.dropFirst(Self.apiPrefix.count))
        expireLocked()
        let parts = sub.split(separator: "/").map(String.init)
        if parts == ["health"] && request.method == "GET" {
            return json(200, CentralHealth(service: Self.serviceName, environment: "development", apiVersion: "proposed-1", time: clock()))
        }
        guard let account = authenticate(request) else {
            return fail(401, CentralErrorCode.unauthorized, "Missing or unknown development session token.")
        }
        if parts == ["account"] && request.method == "GET" { return json(200, account) }
        if parts == ["gateways"] && request.method == "POST" { return registerGateway(request, account: account) }
        guard let gateway = authenticateGateway(request, account: account) else {
            return fail(401, CentralErrorCode.gatewaySignatureInvalid, "Gateway signature missing, invalid, replayed, or gateway not registered to this account.")
        }
        switch (request.method, parts.count) {
        case ("POST", 1) where parts[0] == "enrollments": return submit(request, account: account, gateway: gateway)
        case ("GET", 2) where parts[0] == "enrollments":
            guard let e = state.enrollments[parts[1]], e.gatewayId == gateway.registration.gatewayId else {
                return fail(404, CentralErrorCode.notFound, "No such enrollment for this gateway.")
            }
            return json(200, e.record)
        case ("GET", 3) where parts[0] == "gateways" && parts[2] == "devices":
            guard parts[1] == gateway.registration.gatewayId else { return fail(403, "forbidden", "Not this gateway.") }
            let devices = state.devices.values.filter { $0.gatewayId == parts[1] }.map(\.record).sorted { $0.deviceId < $1.deviceId }
            return json(200, CentralDeviceList(gatewayId: parts[1], devices: devices))
        case ("POST", 3) where parts[0] == "gateways" && parts[2] == "events":
            guard parts[1] == gateway.registration.gatewayId else { return fail(403, "forbidden", "Not this gateway.") }
            guard let batch = try? Wire.decoder().decode(GatewayEventBatch.self, from: request.body) else {
                return fail(400, CentralErrorCode.invalidInput, "Malformed events.")
            }
            let known = Set(state.events.map(\.event.eventId))
            for e in batch.events where !known.contains(e.eventId) {
                state.events.append(StoredEvent(gatewayId: parts[1], event: e, receivedAt: clock()))
            }
            if state.events.count > 2000 { state.events.removeFirst(state.events.count - 2000) }
            save()
            return HTTPResponse.json(202, Data("{\"accepted\":\(batch.events.count)}".utf8))
        default:
            return fail(404, CentralErrorCode.notFound, "Unknown endpoint.")
        }
    }

    static func tokenKey(_ token: String) -> String { Encoding.sha256Hex(Data(("hcgdev-token:" + token).utf8)) }

    func handleSignIn(_ request: HTTPRequest) -> HTTPResponse {
        struct In: Decodable { var email: String; var displayName: String? }
        guard let body = try? Wire.decoder().decode(In.self, from: request.body),
              body.email.contains("@"), body.email.count <= 200 else {
            return fail(400, CentralErrorCode.invalidInput, "Provide an email address for the development account.")
        }
        let token = "hcgdev_tok_" + Encoding.base64url(Encoding.randomBytes(24))
        let existing = state.accounts.values.first { $0.email.lowercased() == body.email.lowercased() }
        let account = existing ?? CentralAccount(accountId: Encoding.randomID(prefix: "hcgdev_acct_"), email: body.email,
                                                 displayName: body.displayName ?? body.email, verified: true,
                                                 mayOwnGateways: true, environment: "development")
        state.accounts[Self.tokenKey(token)] = account
        note("sign-in", account.accountId, account.email)
        save()
        struct Out: Encodable { var accessToken: String; var account: CentralAccount }
        return json(200, Out(accessToken: token, account: account))
    }

    func authenticate(_ request: HTTPRequest) -> CentralAccount? {
        guard let h = request.headers["authorization"], h.hasPrefix("Bearer ") else { return nil }
        return state.accounts[Self.tokenKey(String(h.dropFirst(7)))]
    }

    func verifyGatewaySignature(_ request: HTTPRequest, publicKeyDER: Data) -> Bool {
        guard let auth = SignedEnvelope.parseRequestAuth(headers: request.headers),
              auth.keyFingerprint == KeyFingerprint.of(publicKeyDER: publicKeyDER) else { return false }
        let input = RequestSigningInput(method: request.method, path: request.path, timestamp: auth.timestamp,
                                        nonce: auth.nonce, keyFingerprint: auth.keyFingerprint, body: request.body)
        guard SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: publicKeyDER) else { return false }
        return replay.check(keyFingerprint: auth.keyFingerprint, nonce: auth.nonce, timestamp: auth.timestamp, now: clock()) == .fresh
    }

    func authenticateGateway(_ request: HTTPRequest, account: CentralAccount) -> StoredGateway? {
        guard let fp = request.headers[OriginHeader.keyFingerprint],
              let gw = state.gateways.values.first(where: { $0.registration.gatewayFingerprint == fp }),
              gw.registration.ownerAccountId == account.accountId,
              let key = Encoding.fromBase64url(gw.publicKey),
              verifyGatewaySignature(request, publicKeyDER: key) else { return nil }
        return gw
    }

    func registerGateway(_ request: HTTPRequest, account: CentralAccount) -> HTTPResponse {
        guard account.verified && account.mayOwnGateways else {
            return fail(403, CentralErrorCode.accountNotPermitted, "This account may not own gateways.")
        }
        guard let body = try? Wire.decoder().decode(GatewayRegistrationRequest.self, from: request.body),
              let key = Encoding.fromBase64url(body.gatewayPublicKey), SignatureVerifier.isValidPublicKey(key) else {
            return fail(400, CentralErrorCode.invalidInput, "Malformed gateway registration.")
        }
        guard verifyGatewaySignature(request, publicKeyDER: key) else {
            return fail(401, CentralErrorCode.gatewaySignatureInvalid, "The registration is not signed by the gateway key.")
        }
        let fp = KeyFingerprint.of(publicKeyDER: key)
        if let existing = state.gateways.values.first(where: { $0.registration.gatewayFingerprint == fp }) {
            guard existing.registration.ownerAccountId == account.accountId else {
                return fail(409, "gateway_owned_elsewhere", "This gateway key is registered to another account.")
            }
            return json(200, existing.registration)
        }
        let reg = GatewayRegistration(gatewayId: Encoding.randomID(prefix: "hcgdev_gw_"), gatewayFingerprint: fp,
                                      ownerAccountId: account.accountId, status: "registered", registeredAt: clock(),
                                      environment: "development")
        state.gateways[reg.gatewayId] = StoredGateway(registration: reg, publicKey: body.gatewayPublicKey, name: body.name)
        note("register-gateway", reg.gatewayId, "\(body.name) (\(body.platform)) for \(account.email)")
        save()
        return json(201, reg)
    }

    func submit(_ request: HTTPRequest, account: CentralAccount, gateway: StoredGateway) -> HTTPResponse {
        guard let s = try? Wire.decoder().decode(CentralEnrollmentSubmission.self, from: request.body) else {
            return fail(400, CentralErrorCode.invalidInput, "Malformed enrollment submission.")
        }
        guard s.gatewayId == gateway.registration.gatewayId else { return fail(403, "forbidden", "Submission names another gateway.") }
        if let existing = state.enrollments.values.first(where: { $0.gatewayId == s.gatewayId && $0.submission.localRequestId == s.localRequestId }) {
            return json(200, existing.record) // idempotent retry
        }
        // Verify the device's own signed request rather than trusting the gateway.
        let f = s.deviceRequest
        var deviceSignature = "invalid"
        var matches = false
        if let deviceKey = s.device.publicKeyDER, let body = Encoding.fromBase64url(f.body), let sig = Encoding.fromBase64url(f.signature),
           KeyFingerprint.of(publicKeyDER: deviceKey) == f.keyFingerprint {
            let input = RequestSigningInput(method: f.method, path: f.path, timestamp: f.timestamp, nonce: f.nonce,
                                            keyFingerprint: f.keyFingerprint, body: body)
            if SignatureVerifier.verify(signatureDER: sig, message: input.bytes, publicKeyDER: deviceKey) { deviceSignature = "valid" }
            if let original = try? Wire.decoder().decode(EnrollRequestBody.self, from: body) {
                matches = original.device == s.device && original.invitationId == s.invitationId
                    && original.gatewayFingerprint == gateway.registration.gatewayFingerprint
                    && Set(s.requestedCapabilities).isSubset(of: Set(original.requestedCapabilities))
                    && f.path == OriginPath.enroll
            }
        }
        guard deviceSignature == "valid" && matches else {
            note("refuse", s.localRequestId, "device signature or content mismatch")
            save()
            return fail(422, CentralErrorCode.deviceSignatureInvalid, "The forwarded device request does not verify or does not match the submission.")
        }
        if s.requestedCapabilities.contains(where: { Capability.isExecutionLike($0) }) {
            return fail(422, CentralErrorCode.invalidInput, "Execution capabilities cannot be requested through enrollment.")
        }
        let fp = f.keyFingerprint
        if let dup = state.devices.values.first(where: { $0.record.fingerprint == fp && $0.record.status == .active && $0.gatewayId == s.gatewayId }) {
            return fail(409, CentralErrorCode.duplicateEnrollment, "This device key is already admitted as \(dup.record.deviceId).")
        }
        if state.enrollments.values.contains(where: { $0.submission.deviceRequest.keyFingerprint == fp && $0.record.state == .pendingReview && $0.gatewayId == s.gatewayId }) {
            return fail(409, CentralErrorCode.duplicateEnrollment, "A request for this device key is already pending review.")
        }
        let now = clock()
        let account_ = account.verified ? "verified" : "unverified"
        let record = CentralEnrollmentRecord(
            enrollmentId: Encoding.randomID(prefix: "hcgdev_enr_"), localRequestId: s.localRequestId, state: .pendingReview,
            verification: CentralVerification(account: account_, deviceSignature: deviceSignature, gatewaySignature: "valid"),
            reason: nil, decidedAt: nil, deviceId: nil, grant: nil, environment: "development")
        state.enrollments[record.enrollmentId] = StoredEnrollment(
            record: record, submission: s, gatewayId: s.gatewayId, ownerAccountId: account.accountId, createdAt: now,
            expiresAt: now.addingTimeInterval(enrollmentTTL),
            checkCode: PairingCheckCode.compute(gatewayFingerprint: gateway.registration.gatewayFingerprint, deviceFingerprint: fp, invitationId: s.invitationId))
        note("submit", record.enrollmentId, "\(s.device.name) via \(gateway.name)")
        save()
        return json(201, record)
    }

    // MARK: Admin (development approver page and scripts)

    func handleAdmin(_ request: HTTPRequest) -> HTTPResponse {
        guard let t = request.headers["x-hcg-dev-admin"], t == adminToken else {
            return fail(401, CentralErrorCode.unauthorized, "Development admin token required (X-HCG-Dev-Admin).")
        }
        expireLocked()
        let parts = request.path.dropFirst("/dev/v1/admin/".count).split(separator: "/").map(String.init)
        struct Decision: Decodable { var capabilities: [String]?; var reason: String?; var note: String? }
        struct Outage: Decodable { var enabled: Bool }
        let decision = (try? Wire.decoder().decode(Decision.self, from: request.body)) ?? Decision()
        do {
            switch (request.method, parts) {
            case ("GET", ["state"]): return json(200, adminState())
            case ("POST", ["outage"]):
                guard let o = try? Wire.decoder().decode(Outage.self, from: request.body) else { throw ControlError.invalid("enabled required") }
                outage = o.enabled
                note("outage", "service", o.enabled ? "Simulated outage ON" : "Simulated outage OFF")
                return json(200, adminState())
            case ("POST", let p) where p.count == 3 && p[0] == "enrollments" && p[2] == "approve":
                try approveLocked(p[1], capabilities: decision.capabilities, note: decision.note)
                return json(200, adminState())
            case ("POST", let p) where p.count == 3 && p[0] == "enrollments" && p[2] == "reject":
                try rejectLocked(p[1], reason: decision.reason ?? "")
                return json(200, adminState())
            case ("POST", let p) where p.count == 3 && p[0] == "devices" && p[2] == "revoke":
                try revokeLocked(p[1], reason: decision.reason ?? "")
                return json(200, adminState())
            default:
                return fail(404, CentralErrorCode.notFound, "Unknown admin endpoint.")
            }
        } catch let e as ControlError {
            return fail(400, CentralErrorCode.invalidInput, e.description)
        } catch {
            return fail(500, "error", "\(error)")
        }
    }

    struct AdminEnrollment: Encodable {
        var enrollmentId: String; var state: String; var deviceName: String; var platform: String; var clientKind: String
        var deviceFingerprint: String; var checkCode: String; var account: String; var gatewayName: String; var gatewayId: String
        var requestedCapabilities: [String]; var refusedByGateway: [CapabilityRefusal]; var verification: CentralVerification
        var createdAt: Date; var expiresAt: Date; var decidedAt: Date?; var reason: String?; var deviceId: String?
    }
    struct AdminState: Encodable {
        var service: String; var environment: String; var outage: Bool
        var enrollments: [AdminEnrollment]; var devices: [CentralDeviceRecord]; var gateways: [GatewayRegistration]
        var events: [GatewayEvent]; var log: [DecisionLog]; var capabilityCatalogue: [CapabilityInfo]
    }

    func adminState() -> AdminState {
        let accounts = Dictionary(state.accounts.values.map { ($0.accountId, $0.email) }, uniquingKeysWith: { a, _ in a })
        let enrollments = state.enrollments.values.sorted { $0.createdAt > $1.createdAt }.map { e in
            AdminEnrollment(enrollmentId: e.record.enrollmentId, state: e.record.state.rawValue, deviceName: e.submission.device.name,
                            platform: e.submission.device.platform, clientKind: e.submission.device.clientKind,
                            deviceFingerprint: e.submission.deviceRequest.keyFingerprint, checkCode: e.checkCode,
                            account: accounts[e.ownerAccountId] ?? e.ownerAccountId,
                            gatewayName: state.gateways[e.gatewayId]?.name ?? e.gatewayId, gatewayId: e.gatewayId,
                            requestedCapabilities: e.submission.requestedCapabilities, refusedByGateway: e.submission.refusedByGateway,
                            verification: e.record.verification, createdAt: e.createdAt, expiresAt: e.expiresAt,
                            decidedAt: e.record.decidedAt, reason: e.record.reason, deviceId: e.record.deviceId)
        }
        return AdminState(service: Self.serviceName, environment: "development", outage: outage, enrollments: enrollments,
                          devices: state.devices.values.map(\.record).sorted { $0.deviceId < $1.deviceId },
                          gateways: state.gateways.values.map(\.registration), events: Array(state.events.suffix(100).map(\.event).reversed()),
                          log: Array(state.log.suffix(100).reversed()), capabilityCatalogue: Capability.catalogue)
    }
}

extension DeviceDescriptor {
    var publicKeyFingerprint: String { publicKeyDER.map { KeyFingerprint.of(publicKeyDER: $0) } ?? "" }
}

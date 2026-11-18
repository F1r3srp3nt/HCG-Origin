import Foundation
import HCGOriginProtocol
import HCGHTTP

public enum PairingError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    public var description: String {
        switch self { case .unavailable(let s): return s }
    }
}

/// The HCG Origin gateway: owns the Connector-facing listener, the enrollment state
/// machine, persistence and synchronisation with central HCG (or the labelled local
/// development service). The macOS app is a view of this engine.
///
/// Invariants:
///  * an invitation only lets a device *submit* a request; admission is decided centrally;
///  * a device can use exactly the capabilities central granted, never execution;
///  * a revoked or locally blocked device is rejected on every request;
///  * secrets (invitation secrets, tokens, keys) are never logged or persisted outside the secret store.
public actor GatewayEngine {
    public typealias CentralFactory = @Sendable (CentralMode, URL, MessageSigner) -> CentralService

    // MARK: Configuration and dependencies
    let files: JSONFileStore
    let secrets: SecretStore
    let production: ProductionConfiguration
    let makeCentral: CentralFactory
    let clock: @Sendable () -> Date
    let hostName: String
    let preferSecureEnclave: Bool

    // MARK: State
    var settings: OriginSettings
    var state = OriginState()
    var identity: GatewayIdentity?
    var startupError: String?
    var listener: HTTPServer?
    var listenerState: ListenerState = .stopped
    var centralStatus: CentralStatus
    var activeInvitation: ActiveInvitation?
    var activity: [ActivityEntry] = []
    var observer: (@Sendable (GatewaySnapshot) -> Void)?
    var loopTask: Task<Void, Never>?
    var syncing = false
    var lastSyncStarted: Date?
    var knownConnection: [String: ConnectionState] = [:]
    let replay = ReplayGuard()
    var lastSecurityLog: [String: Date] = [:]

    public init(dataDirectory: URL, secrets: SecretStore, production: ProductionConfiguration,
                hostName: String, preferSecureEnclave: Bool = true,
                clock: @escaping @Sendable () -> Date = { Date() },
                makeCentral: CentralFactory? = nil) {
        self.files = JSONFileStore(directory: dataDirectory)
        self.secrets = secrets
        self.production = production
        self.hostName = hostName
        self.preferSecureEnclave = preferSecureEnclave
        self.clock = clock
        self.makeCentral = makeCentral ?? { mode, url, signer in HTTPCentralService(mode: mode, baseURL: url, signer: signer) }
        let loaded = files.load(OriginSettings.self, from: "settings.json") ?? OriginSettings.defaults(hostName: hostName)
        self.settings = loaded
        self.centralStatus = CentralStatus(mode: loaded.centralMode, serviceURL: nil, reachability: .unknown, lastSyncAt: nil, lastError: nil)
    }

    // MARK: Lifecycle

    public func setObserver(_ observer: @escaping @Sendable (GatewaySnapshot) -> Void) {
        self.observer = observer
        notify()
    }

    public func start(runLoop: Bool = true) async {
        state = files.load(OriginState.self, from: "state.json") ?? OriginState()
        activity = files.readLines("activity.jsonl", last: 500).compactMap { try? Wire.decoder().decode(ActivityEntry.self, from: $0) }
        do {
            identity = try GatewayIdentity.loadOrCreate(store: secrets, preferSecureEnclave: preferSecureEnclave)
        } catch {
            startupError = "\(error)"
            log(.error, .error, "Gateway identity unavailable", "\(error)")
            notify()
            return
        }
        // Invitations never survive a restart: their secrets were only in memory.
        for i in state.invitations.indices where state.invitations[i].status == .active {
            state.invitations[i].status = .cancelled
        }
        for d in state.devices { knownConnection[d.id] = d.connectionState(now: clock(), disconnectAfter: disconnectAfter) }
        persist()
        log(.gateway, .info, "Gateway started", "Origin \(OriginVersion.marketing), environment \(settings.centralMode.rawValue).")
        startListener()
        refreshCentralStatusFromConfiguration()
        notify()
        if runLoop {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    public func shutdown() {
        loopTask?.cancel()
        loopTask = nil
        cancelPairing(reason: "Origin stopped")
        listener?.stop()
        listener = nil
        listenerState = .stopped
        persist()
        notify()
    }

    var disconnectAfter: TimeInterval { TimeInterval(settings.disconnectAfterSeconds) }

    // MARK: Snapshot

    public func snapshot() -> GatewaySnapshot {
        let now = clock()
        let env = settings.centralMode.wireEnvironment
        return GatewaySnapshot(
            now: now, settings: settings,
            gatewayFingerprint: identity?.fingerprint ?? "",
            proposedGatewayId: identity?.proposedGatewayId ?? "",
            keyStorage: identity?.keyStorage ?? "unavailable",
            secretStorage: secrets.kindDescription,
            listener: listenerState, central: centralStatus,
            account: state.accounts[env], registration: currentRegistration,
            production: production, pairing: pairingAvailability(),
            activeInvitation: activeInvitation,
            requests: state.requests.sorted { $0.receivedAt > $1.receivedAt },
            devices: state.devices.sorted { $0.enrolledAt > $1.enrolledAt }.map {
                DeviceView(record: $0, connection: $0.connectionState(now: now, disconnectAfter: disconnectAfter))
            },
            activity: Array(activity.suffix(500).reversed()),
            startupError: startupError)
    }

    func notify() {
        guard let observer else { return }
        observer(snapshot())
    }

    func persist() {
        do { try files.save(state, to: "state.json") }
        catch { OriginLog.error("could not save state: \(error)") }
    }

    func saveSettings() {
        do { try files.save(settings, to: "settings.json") }
        catch { OriginLog.error("could not save settings: \(error)") }
    }

    // MARK: Activity

    func log(_ kind: ActivityKind, _ severity: ActivitySeverity, _ title: String, _ detail: String,
             deviceId: String? = nil, requestId: String? = nil) {
        let entry = ActivityEntry(id: Encoding.randomID(prefix: "act_"), at: clock(), kind: kind, severity: severity,
                                  title: title, detail: detail, environment: settings.centralMode.wireEnvironment,
                                  deviceId: deviceId, requestId: requestId)
        activity.append(entry)
        if activity.count > 1000 { activity.removeFirst(activity.count - 1000) }
        files.append(line: Wire.encode(entry), to: "activity.jsonl")
        OriginLog.info("[\(kind.rawValue)] \(title) — \(detail)")
    }

    /// Security events from unauthenticated callers are rate limited per category.
    func securityLog(_ key: String, _ title: String, _ detail: String) {
        let now = clock()
        if let last = lastSecurityLog[key], now.timeIntervalSince(last) < 10 { return }
        lastSecurityLog[key] = now
        log(.security, .warning, title, detail)
    }

    func queueEvent(_ type: String, deviceId: String? = nil, requestId: String? = nil, detail: String) {
        state.pendingEvents.append(GatewayEvent(eventId: Encoding.randomID(prefix: "evt_"), type: type, occurredAt: clock(),
                                                deviceId: deviceId, localRequestId: requestId, detail: detail))
        if state.pendingEvents.count > 500 { state.pendingEvents.removeFirst(state.pendingEvents.count - 500) }
    }

    // MARK: Listener

    func startListener() {
        listener?.stop()
        listener = nil
        let host = settings.allowLocalNetwork ? "0.0.0.0" : "127.0.0.1"
        let server = HTTPServer(host: host, port: settings.listenPort) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503) }
            return await self.handle(request)
        }
        do {
            let port = try server.start()
            listener = server
            let shown = settings.allowLocalNetwork ? "\(NetworkAddress.primaryLANAddress() ?? "0.0.0.0"):\(port)" : "127.0.0.1:\(port)"
            listenerState = .listening(address: shown, localNetwork: settings.allowLocalNetwork)
            log(.gateway, .info, "Listening for Connector requests", settings.allowLocalNetwork
                ? "On the local network at \(shown). Only signed requests with a valid invitation are accepted."
                : "On this Mac only (\(shown)).")
        } catch {
            listenerState = .failed("\(error)")
            log(.error, .error, "Gateway listener failed", "\(error)")
        }
    }

    public func restartListener() {
        cancelPairing(reason: "Listener restarted")
        startListener()
        notify()
    }

    var invitationAddress: String? {
        guard case .listening = listenerState, let port = listener?.port else { return nil }
        if settings.allowLocalNetwork {
            guard let lan = NetworkAddress.primaryLANAddress() else { return nil }
            return "\(lan):\(port)"
        }
        return "127.0.0.1:\(port)"
    }

    // MARK: Settings

    public func updateSettings(_ change: @Sendable (inout OriginSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let old = settings
        settings = next
        saveSettings()
        if old.centralMode != next.centralMode {
            cancelPairing(reason: "Central environment changed")
            for i in state.requests.indices where state.requests[i].isOpen && state.requests[i].environment == old.centralMode.wireEnvironment {
                state.requests[i].state = .expired
                state.requests[i].decisionReason = "Central environment changed to \(next.centralMode.rawValue) before a decision."
            }
            log(.central, next.centralMode == .development ? .warning : .info,
                "Central environment: \(next.centralMode == .development ? "LOCAL DEVELOPMENT SERVICE" : "Production HCG")",
                next.centralMode == .development
                    ? "Results come from the local development service on this Mac. They are not HCG verification."
                    : "Production enrollment requires HCG Connect sign-in and the central HCG Origin API.")
            persist()
        }
        if old.listenPort != next.listenPort || old.allowLocalNetwork != next.allowLocalNetwork {
            cancelPairing(reason: "Connection settings changed")
            startListener()
        }
        if old.gatewayName != next.gatewayName {
            log(.gateway, .info, "Gateway renamed", "New name: \(next.gatewayName). Existing devices keep their enrollment.")
        }
        refreshCentralStatusFromConfiguration()
        notify()
    }

    // MARK: Account

    var currentRegistration: GatewayCentralRecord? {
        guard let reg = state.registrations[settings.centralMode.wireEnvironment],
              reg.serviceURL == centralBaseURL()?.absoluteString else { return nil }
        return reg
    }

    func tokenName(_ env: String) -> String { "session-token.\(env)" }

    func currentToken() -> String? {
        guard let data = try? secrets.read(tokenName(settings.centralMode.wireEnvironment)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func signInDevelopment(email: String, displayName: String) async throws {
        guard settings.centralMode == .development, let url = URL(string: settings.developmentServiceURL) else {
            throw CentralError.malformed("Switch to the local development service first.")
        }
        let response = try await DevelopmentSignIn.signIn(serviceURL: url, email: email, displayName: displayName)
        try secrets.write(tokenName(CentralMode.development.wireEnvironment), Data(response.accessToken.utf8))
        state.accounts[CentralMode.development.wireEnvironment] = response.account
        persist()
        log(.account, .warning, "Signed in to the local development service",
            "\(response.account.email) — a development account, not an HCG Connect sign-in.")
        notify()
        await syncCentral(force: true)
    }

    /// Stores tokens from a completed HCG Connect sign-in (production only).
    public func completeProductionSignIn(accessToken: String) async throws {
        guard production.isComplete, let base = URL(string: production.centralOriginAPIBase), let identity else {
            throw CentralError.notConfigured(production.problems)
        }
        let central = makeCentral(.production, base, identity.signer)
        let account = try await central.account(token: accessToken)
        try secrets.write(tokenName(CentralMode.production.wireEnvironment), Data(accessToken.utf8))
        state.accounts[CentralMode.production.wireEnvironment] = account
        persist()
        log(.account, .success, "Signed in with HCG Connect", account.email)
        notify()
        await syncCentral(force: true)
    }

    public func signOut() {
        let env = settings.centralMode.wireEnvironment
        try? secrets.delete(tokenName(env))
        let email = state.accounts[env]?.email ?? "account"
        state.accounts[env] = nil
        cancelPairing(reason: "Signed out")
        persist()
        log(.account, .info, "Signed out", "\(email) on \(env). Local tokens were removed; enrolled devices are unchanged.")
        notify()
    }

    // MARK: Central

    func centralBaseURL() -> URL? {
        switch settings.centralMode {
        case .production: return production.isComplete ? URL(string: production.centralOriginAPIBase) : nil
        case .development: return URL(string: settings.developmentServiceURL)
        }
    }

    func refreshCentralStatusFromConfiguration() {
        centralStatus.mode = settings.centralMode
        centralStatus.serviceURL = centralBaseURL()?.absoluteString
        if settings.centralMode == .production && !production.isComplete {
            centralStatus.reachability = .notConfigured(production.problems)
        } else if case .notConfigured = centralStatus.reachability {
            centralStatus.reachability = .unknown
        }
    }

    func central() -> CentralService? {
        guard let identity, let url = centralBaseURL() else { return nil }
        if settings.centralMode == .development && !HTTPClient.isLoopback(url) { return nil }
        return makeCentral(settings.centralMode, url, identity.signer)
    }

    /// Runs a full synchronisation now, after any one already in progress.
    public func syncNow() async {
        var waited = 0
        while syncing && waited < 500 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        await syncCentral(force: true)
    }

    func syncCentral(force: Bool = false) async {
        if syncing { return }
        let now = clock()
        if !force, let last = lastSyncStarted, now.timeIntervalSince(last) < TimeInterval(settings.centralSyncSeconds) { return }
        syncing = true
        lastSyncStarted = now
        defer { syncing = false }
        refreshCentralStatusFromConfiguration()
        guard let central = central(), let identity else { notify(); return }
        let env = settings.centralMode.wireEnvironment
        let wasReachable: Bool = { if case .reachable = centralStatus.reachability { return true }; return false }()

        do {
            let health = try await central.health()
            centralStatus.reachability = .reachable(service: health.service, at: clock())
            if !wasReachable { log(.central, .success, "Central service reachable", "\(health.service) (\(health.environment)).") }
        } catch let e as CentralError {
            if case .environmentMismatch = e {
                centralStatus.reachability = .mismatch(e.description)
            } else if case .unreachable(_, let since) = centralStatus.reachability {
                centralStatus.reachability = .unreachable(e.description, since: since)
            } else {
                centralStatus.reachability = .unreachable(e.description, since: clock())
                log(.central, .error, "Central service unreachable", e.description + " Requests stay pending and are retried.")
            }
            centralStatus.lastError = e.description
            notify()
            return
        } catch {
            centralStatus.reachability = .unreachable("\(error)", since: clock())
            notify()
            return
        }

        guard let token = currentToken() else {
            centralStatus.lastError = "Not signed in."
            notify()
            return
        }

        do {
            // 1. Gateway registration (issued by central, never derived locally).
            if currentRegistration == nil {
                let reg = try await central.registerGateway(GatewayRegistrationRequest(
                    gatewayPublicKey: identity.publicKeyBase64url, proposedGatewayId: identity.proposedGatewayId,
                    name: settings.gatewayName, platform: Self.platformDescription, originVersion: OriginVersion.marketing), token: token)
                guard reg.gatewayFingerprint == identity.fingerprint, reg.environment == env else {
                    throw CentralError.malformed("registration does not match this gateway")
                }
                state.registrations[env] = GatewayCentralRecord(gatewayId: reg.gatewayId, environment: env,
                    serviceURL: central.baseURL.absoluteString, ownerAccountId: reg.ownerAccountId, registeredAt: reg.registeredAt)
                persist()
                log(.central, .success, "Gateway registered", "Central issued gateway ID \(reg.gatewayId).")
            }
            guard let reg = currentRegistration else { return }

            // 2. Submit and follow open requests.
            for id in state.requests.filter({ $0.isOpen && $0.environment == env }).map(\.id) {
                await syncRequest(id: id, central: central, token: token, gatewayId: reg.gatewayId)
            }

            // 3. Admission state of enrolled devices (revocation, narrowed grants).
            let list = try await central.devices(gatewayId: reg.gatewayId, token: token)
            applyDeviceList(list, environment: env)

            // 4. Audit events.
            if !state.pendingEvents.isEmpty {
                let batch = Array(state.pendingEvents.prefix(50))
                try await central.report(events: batch, gatewayId: reg.gatewayId, token: token)
                let sent = Set(batch.map(\.eventId))
                state.pendingEvents.removeAll { sent.contains($0.eventId) }
            }
            centralStatus.lastSyncAt = clock()
            centralStatus.lastError = nil
            persist()
        } catch let e as CentralError {
            centralStatus.lastError = e.description
            if case .unauthorized = e {
                log(.account, .error, "Central service did not accept the sign-in", e.description + " Sign in again.")
                try? secrets.delete(tokenName(env))
                state.accounts[env] = nil
                cancelPairing(reason: "Sign-in no longer accepted")
                persist()
            } else if e.isTransient {
                centralStatus.reachability = .unreachable(e.description, since: clock())
            } else {
                log(.central, .error, "Central synchronisation failed", e.description)
            }
        } catch {
            centralStatus.lastError = "\(error)"
        }
        notify()
    }

    static var platformDescription: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        return "macOS \(v.majorVersion).\(v.minorVersion) (Apple silicon)"
        #else
        return "macOS \(v.majorVersion).\(v.minorVersion) (Intel)"
        #endif
        #else
        return "Linux (development only)"
        #endif
    }

    func syncRequest(id: String, central: CentralService, token: String, gatewayId: String) async {
        guard let record = state.requests.first(where: { $0.id == id }), record.isOpen else { return }
        let now = clock()
        if let next = record.nextCentralAttemptAt, next > now { return }
        do {
            let result: CentralEnrollmentRecord
            if let cid = record.centralEnrollmentId {
                result = try await central.enrollment(id: cid, token: token)
            } else {
                result = try await central.submitEnrollment(CentralEnrollmentSubmission(
                    gatewayId: gatewayId, localRequestId: record.id, invitationId: record.invitationId, device: record.device,
                    requestedCapabilities: record.forwardedCapabilities, refusedByGateway: record.refusedCapabilities,
                    deviceRequest: record.forwarded, receivedAt: record.receivedAt), token: token)
            }
            applyCentral(result, to: id)
        } catch let e as CentralError {
            guard let i = state.requests.firstIndex(where: { $0.id == id }) else { return }
            state.requests[i].centralAttempts += 1
            state.requests[i].lastCentralError = e.description
            let delay = min(60.0, pow(2.0, Double(min(state.requests[i].centralAttempts, 6))))
            state.requests[i].nextCentralAttemptAt = clock().addingTimeInterval(delay)
            if case .rejected(let status, let code, let message) = e, status == 409 || status == 422 || status == 403 || status == 400 {
                // Central refused the submission itself (duplicate, account not permitted, invalid).
                state.requests[i].state = status == 409 ? .rejected : .failed
                state.requests[i].decisionReason = "\(code): \(message)"
                state.requests[i].decidedAt = clock()
                markStep(i, "central", .failed, "\(code): \(message)")
                log(.decision, .error, "Central refused the enrollment request", "\(state.requests[i].device.name): \(code) — \(message)",
                    requestId: id)
            } else if state.requests[i].centralAttempts == 1 || state.requests[i].centralAttempts % 10 == 0 {
                markStep(i, "central", .pending, "Not yet accepted: \(e.description) Retrying.")
                log(.central, .warning, "Request not yet forwarded", "\(state.requests[i].device.name): \(e.description) Retrying automatically.",
                    requestId: id)
            }
            persist()
        } catch {
            OriginLog.error("request sync failed: \(error)")
        }
    }

    func markStep(_ index: Int, _ stepId: String, _ result: VerificationStep.Result, _ detail: String?) {
        if let s = state.requests[index].steps.firstIndex(where: { $0.id == stepId }) {
            state.requests[index].steps[s].result = result
            state.requests[index].steps[s].detail = detail
            state.requests[index].steps[s].at = clock()
        }
    }

    func applyCentral(_ result: CentralEnrollmentRecord, to id: String) {
        guard let i = state.requests.firstIndex(where: { $0.id == id }), state.requests[i].isOpen else { return }
        let source = settings.centralMode == .development ? "local development service" : "HCG ERP"
        let firstAcceptance = state.requests[i].centralEnrollmentId == nil
        state.requests[i].centralEnrollmentId = result.enrollmentId
        state.requests[i].centralState = result.state.rawValue
        state.requests[i].lastCentralError = nil
        state.requests[i].nextCentralAttemptAt = nil
        let v = result.verification
        let accountOK = v.account == "verified"
        markStep(i, "central", accountOK && v.deviceSignature == "valid" && v.gatewaySignature == "valid" ? .passed : .failed,
                 "Account \(v.account), device signature \(v.deviceSignature), gateway signature \(v.gatewaySignature) (\(source)).")
        if firstAcceptance {
            log(.enrollment, .info, "Forwarded to \(source)", "\(state.requests[i].device.name): central enrollment \(result.enrollmentId).", requestId: id)
        }
        switch result.state {
        case .pendingReview:
            state.requests[i].state = .awaitingDecision
            markStep(i, "decision", .pending, "Waiting for the authorised person to decide in \(source == "HCG ERP" ? "ERP" : "the development ERP page").")
        case .approved:
            guard let deviceId = result.deviceId, let grantIn = result.grant else {
                markStep(i, "decision", .failed, "Approval without device ID or grant was ignored.")
                return
            }
            var grant = grantIn
            let (allowed, refused) = Capability.screen(grant.capabilities)
            grant.capabilities = allowed.filter { state.requests[i].forwardedCapabilities.contains($0) }
            grant.executionAuthorized = false
            state.requests[i].state = .approved
            state.requests[i].decidedAt = result.decidedAt ?? clock()
            state.requests[i].issuedDeviceId = deviceId
            state.requests[i].grant = grant
            state.requests[i].decisionReason = result.reason
            markStep(i, "decision", .passed, "Approved by \(source): \(grant.capabilities.joined(separator: ", ")).")
            let r = state.requests[i]
            state.devices.removeAll { $0.fingerprint == r.deviceFingerprint || $0.id == deviceId }
            state.devices.append(DeviceRecord(
                id: deviceId, proposedDeviceId: r.device.proposedDeviceId, name: r.device.name, platform: r.device.platform,
                model: r.device.model, softwareVersion: r.device.softwareVersion, clientKind: r.device.clientKind,
                fingerprint: r.deviceFingerprint, publicKey: r.device.publicKey, grant: grant, environment: r.environment,
                enrollmentRequestId: r.id, enrolledAt: clock(), status: .active, statusChangedAt: clock(), statusReason: nil,
                lastContactAt: nil, lastContactFrom: nil, lastSequence: nil, lastReport: nil, connectedSince: nil, lastRejectedAt: nil))
            knownConnection[deviceId] = .awaitingFirstContact
            log(.decision, .success, "Enrollment approved by \(source)",
                "\(r.device.name) is enrolled as \(deviceId) with \(grant.capabilities.joined(separator: ", ")). Command execution was not granted."
                + (refused.isEmpty ? "" : " Ignored grants: \(refused.map(\.capability).joined(separator: ", ")).")
                + (settings.centralMode == .development ? " DEVELOPMENT ONLY — not HCG verification." : ""),
                deviceId: deviceId, requestId: r.id)
        case .rejected:
            state.requests[i].state = .rejected
            state.requests[i].decidedAt = result.decidedAt ?? clock()
            state.requests[i].decisionReason = result.reason ?? "Rejected"
            markStep(i, "decision", .failed, "Rejected by \(source)" + (result.reason.map { ": \($0)" } ?? "."))
            log(.decision, .warning, "Enrollment rejected by \(source)",
                "\(state.requests[i].device.name)" + (result.reason.map { ": \($0)" } ?? "."), requestId: id)
        case .expired:
            state.requests[i].state = .expired
            state.requests[i].decidedAt = clock()
            state.requests[i].decisionReason = result.reason ?? "Expired without a decision."
            markStep(i, "decision", .failed, "Expired centrally without a decision.")
            log(.decision, .warning, "Enrollment expired", "\(state.requests[i].device.name): no decision was made in time.", requestId: id)
        }
        persist()
    }

    func applyDeviceList(_ list: CentralDeviceList, environment env: String) {
        let byFingerprint = Dictionary(list.devices.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        let source = settings.centralMode == .development ? "local development service" : "HCG ERP"
        for i in state.devices.indices where state.devices[i].environment == env && state.devices[i].status == .active {
            let d = state.devices[i]
            guard let c = byFingerprint[d.fingerprint], c.deviceId == d.id else {
                revoke(index: i, reason: "No longer admitted by \(source).")
                continue
            }
            if c.status == .revoked {
                revoke(index: i, reason: c.revocationReason ?? "Revoked by \(source).")
                continue
            }
            let narrowed = d.grant.capabilities.filter { c.grant.capabilities.contains($0) }
            if narrowed != d.grant.capabilities {
                state.devices[i].grant.capabilities = narrowed
                log(.revocation, .warning, "Permissions reduced", "\(d.name): now \(narrowed.joined(separator: ", ")).", deviceId: d.id)
            }
        }
    }

    func revoke(index i: Int, reason: String) {
        state.devices[i].status = .revoked
        state.devices[i].statusChangedAt = clock()
        state.devices[i].statusReason = reason
        state.devices[i].connectedSince = nil
        knownConnection[state.devices[i].id] = .revoked
        queueEvent("gateway.device.revocation_enforced", deviceId: state.devices[i].id, detail: reason)
        log(.revocation, .warning, "Device access revoked", "\(state.devices[i].name): \(reason) Origin now rejects all of its requests.",
            deviceId: state.devices[i].id)
    }

    // MARK: Local device controls

    /// Blocks a device on this gateway only. ERP admission is unchanged and reported as an audit event.
    public func blockDeviceLocally(id: String) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }), state.devices[i].status == .active else { return }
        state.devices[i].status = .blockedLocally
        state.devices[i].statusChangedAt = clock()
        state.devices[i].statusReason = "Blocked on this gateway by its owner."
        state.devices[i].connectedSince = nil
        knownConnection[id] = .blocked
        queueEvent("gateway.device.blocked_locally", deviceId: id, detail: "Owner blocked the device on this gateway.")
        log(.revocation, .warning, "Device blocked on this gateway", "\(state.devices[i].name). ERP admission is unchanged; revoke it in ERP to remove it everywhere.",
            deviceId: id)
        persist()
        notify()
    }

    public func unblockDevice(id: String) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }), state.devices[i].status == .blockedLocally else { return }
        state.devices[i].status = .active
        state.devices[i].statusChangedAt = clock()
        state.devices[i].statusReason = nil
        queueEvent("gateway.device.unblocked_locally", deviceId: id, detail: "Owner unblocked the device on this gateway.")
        log(.connection, .info, "Device unblocked", "\(state.devices[i].name). Central admission is checked on the next sync.", deviceId: id)
        persist()
        notify()
    }

    public func removeDeviceRecord(id: String) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }), state.devices[i].status != .active else { return }
        let name = state.devices[i].name
        state.devices.remove(at: i)
        log(.gateway, .info, "Device record removed", "\(name) was removed from this list.", deviceId: id)
        persist()
        notify()
    }

    public func dismissRequest(id: String) {
        guard let i = state.requests.firstIndex(where: { $0.id == id }), !state.requests[i].isOpen else { return }
        state.requests.remove(at: i)
        persist()
        notify()
    }

    // MARK: Pairing

    func pairingAvailability() -> PairingAvailability {
        if let startupError { return .unavailable(startupError) }
        guard case .listening = listenerState else {
            return .unavailable("The gateway is not listening for Connector requests. Check Account & Settings → Connection.")
        }
        if settings.allowLocalNetwork && NetworkAddress.primaryLANAddress() == nil {
            return .unavailable("Local network pairing is on, but this Mac has no private network address.")
        }
        switch settings.centralMode {
        case .production:
            if !production.isComplete {
                return .unavailable("Production enrollment is unavailable: HCG Origin is not yet registered with HCG Connect and the central HCG Origin API does not exist yet. Missing: " + production.problems.joined(separator: "; ") + ".")
            }
            if currentToken() == nil { return .unavailable("Sign in with HCG Connect to pair devices.") }
        case .development:
            if currentToken() == nil { return .unavailable("Sign in to the local development service to pair devices.") }
        }
        switch centralStatus.reachability {
        case .reachable: break
        case .mismatch(let m): return .unavailable(m)
        case .unreachable(let d, _): return .unavailable("The central service is unreachable (\(d)). Pairing resumes when it is back.")
        default: return .unavailable("Checking the central service…")
        }
        if currentRegistration == nil { return .unavailable("Registering this gateway with the central service…") }
        return .available
    }

    /// Creates a new single-use invitation. The person must explicitly start this.
    public func startPairing() throws -> ActiveInvitation {
        if case .unavailable(let reason) = pairingAvailability() { throw PairingError.unavailable(reason) }
        guard let identity, let address = invitationAddress else { throw PairingError.unavailable("The gateway is not listening.") }
        cancelPairing(reason: "Replaced by a new invitation")
        let now = clock()
        let ttl = settings.clampedInvitationTTL
        let id = Encoding.randomID(prefix: "inv_")
        let secret = InvitationCode.newSecret()
        let env = settings.centralMode.wireEnvironment
        let payload = InvitationPayload(invitationId: id, secret: secret, gatewayFingerprint: identity.fingerprint,
                                        gatewayName: settings.gatewayName, address: address,
                                        expiresAt: Int64(now.addingTimeInterval(ttl).timeIntervalSince1970), environment: env)
        let code: String
        do { code = try InvitationCode.encode(payload) } catch { throw PairingError.unavailable("Could not create an invitation: \(error)") }
        let expires = Date(timeIntervalSince1970: TimeInterval(payload.expiresAt))
        state.invitations.append(InvitationRecord(id: id, secretHash: InvitationCode.hashSecret(secret), createdAt: now, expiresAt: expires,
                                                  status: .active, usedAt: nil, usedByFingerprint: nil, failedProofs: 0,
                                                  environment: env, address: address))
        if state.invitations.count > 200 { state.invitations.removeFirst(state.invitations.count - 200) }
        activeInvitation = ActiveInvitation(id: id, code: code, createdAt: now, expiresAt: expires, address: address, environment: env)
        pendingSecrets[id] = secret
        persist()
        log(.pairing, .info, "Pairing started", "Invitation \(id) for \(address), valid until \(Self.timeFormatter.string(from: expires)). Single use.")
        notify()
        return activeInvitation!
    }

    /// Secrets of active invitations, in memory only (Origin persists only hashes).
    var pendingSecrets: [String: String] = [:]

    public func cancelPairing() { cancelPairing(reason: "Cancelled by the owner") }

    func cancelPairing(reason: String) {
        guard let active = activeInvitation else { return }
        activeInvitation = nil
        pendingSecrets[active.id] = nil
        if let i = state.invitations.firstIndex(where: { $0.id == active.id }), state.invitations[i].status == .active {
            state.invitations[i].status = .cancelled
            log(.pairing, .info, "Pairing invitation cancelled", "\(active.id): \(reason).")
        }
        persist()
        notify()
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Periodic work

    public func tick() async {
        let now = clock()
        var changed = false
        for i in state.invitations.indices where state.invitations[i].status == .active && state.invitations[i].expiresAt <= now {
            state.invitations[i].status = .expired
            pendingSecrets[state.invitations[i].id] = nil
            if activeInvitation?.id == state.invitations[i].id { activeInvitation = nil }
            log(.pairing, .info, "Pairing invitation expired", "\(state.invitations[i].id) was not used in time.")
            changed = true
        }
        for i in state.requests.indices where state.requests[i].isOpen && state.requests[i].expiresAt <= now {
            state.requests[i].state = .expired
            state.requests[i].decidedAt = now
            state.requests[i].decisionReason = "No decision within \(settings.requestTTLSeconds / 60) minutes."
            markStep(i, "decision", .failed, "Expired locally without a decision.")
            queueEvent("gateway.enrollment.expired_locally", requestId: state.requests[i].id, detail: "No decision in time.")
            log(.enrollment, .warning, "Enrollment request expired", "\(state.requests[i].device.name): no decision in time.", requestId: state.requests[i].id)
            changed = true
        }
        for d in state.devices {
            let c = d.connectionState(now: now, disconnectAfter: disconnectAfter)
            if knownConnection[d.id] == .connected && c == .disconnected {
                log(.connection, .warning, "Device disconnected", "\(d.name): no authenticated contact for \(settings.disconnectAfterSeconds) s.", deviceId: d.id)
                queueEvent("gateway.device.disconnected", deviceId: d.id, detail: "Heartbeat timeout")
                changed = true
            }
            knownConnection[d.id] = c
        }
        if changed { persist() }
        await syncCentral()
        notify()
    }

    // MARK: Connector API

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let nonce = request.headers[OriginHeader.nonce].flatMap { SignedEnvelope.isWellFormedNonce($0) ? $0 : nil } ?? "none"
        if !settings.allowLocalNetwork && !request.remoteAddress.hasPrefix("127.") {
            return error(403, "local_network_disabled", "This gateway accepts requests from this Mac only.", nonce: nonce)
        }
        if settings.allowLocalNetwork && !request.remoteAddress.hasPrefix("127."),
           let url = URL(string: "http://\(request.remoteAddress)/"), !HTTPPrivate.isPrivate(url) {
            securityLog("public-\(request.remoteAddress)", "Request from a public address refused", request.remoteAddress)
            return error(403, "address_not_allowed", "Only devices on this Mac or the private local network may connect.", nonce: nonce)
        }
        guard request.method == "POST" else {
            return error(405, OriginErrorCode.badRequest, "Use POST with a signed request.", nonce: nonce)
        }
        guard identity != nil else { return error(503, "gateway_unavailable", "The gateway identity is unavailable.", nonce: nonce) }
        guard let auth = SignedEnvelope.parseRequestAuth(headers: request.headers) else {
            securityLog("unsigned", "Unsigned request rejected", "From \(request.remoteAddress) to \(request.path).")
            return error(401, OriginErrorCode.unauthenticated, "Missing or malformed HCG Origin signature headers.", nonce: nonce)
        }
        let input = RequestSigningInput(method: request.method, path: request.path, timestamp: auth.timestamp, nonce: auth.nonce,
                                        keyFingerprint: auth.keyFingerprint, body: request.body)
        let response: HTTPResponse
        switch request.path {
        case OriginPath.enroll: response = handleEnroll(request, auth: auth, input: input)
        case OriginPath.enrollmentStatus: response = handleStatus(request, auth: auth, input: input)
        case OriginPath.heartbeat: response = handleHeartbeat(request, auth: auth, input: input)
        default: response = error(404, OriginErrorCode.notFound, "Unknown endpoint.", nonce: auth.nonce)
        }
        notify()
        return response
    }

    func signed(_ status: Int, _ body: Data, nonce: String) -> HTTPResponse {
        guard let identity, let headers = try? SignedEnvelope.signResponse(status: status, body: body, requestNonce: nonce,
                                                                             signer: identity.signer, now: clock()) else {
            return HTTPResponse.json(500, Data())
        }
        return HTTPResponse.json(status, body, headers: headers)
    }

    func respond<T: Encodable>(_ status: Int, _ value: T, nonce: String) -> HTTPResponse {
        signed(status, Wire.encode(value), nonce: nonce)
    }

    func error(_ status: Int, _ code: String, _ message: String, nonce: String, requestId: String? = nil) -> HTTPResponse {
        respond(status, ErrorBody(code: code, message: message, requestId: requestId), nonce: nonce)
    }

    func checkReplay(_ auth: SignedEnvelope.RequestAuth, from: String) -> HTTPResponse? {
        switch replay.check(keyFingerprint: auth.keyFingerprint, nonce: auth.nonce, timestamp: auth.timestamp, now: clock()) {
        case .fresh: return nil
        case .stale:
            securityLog("stale-\(auth.keyFingerprint)", "Stale request rejected", "Key \(KeyFingerprint.short(auth.keyFingerprint)) from \(from): clock difference over \(Int(OriginProtocol.maxClockSkew)) s.")
            return error(401, OriginErrorCode.staleRequest, "Request timestamp is outside the accepted window. Check the device clock.", nonce: auth.nonce)
        case .replayed:
            securityLog("replay-\(auth.keyFingerprint)", "Replayed request rejected", "Key \(KeyFingerprint.short(auth.keyFingerprint)) from \(from) reused a nonce.")
            return error(401, OriginErrorCode.replayedRequest, "This request was already received.", nonce: auth.nonce)
        }
    }

    func handleEnroll(_ request: HTTPRequest, auth: SignedEnvelope.RequestAuth, input: RequestSigningInput) -> HTTPResponse {
        let n = auth.nonce
        guard let identity else { return error(503, "gateway_unavailable", "Gateway identity unavailable.", nonce: n) }
        guard let body = try? Wire.decoder().decode(EnrollRequestBody.self, from: request.body),
              body.type == EnrollRequestBody.typeValue, body.device.isWellFormed, let deviceKey = body.device.publicKeyDER else {
            return error(400, OriginErrorCode.badRequest, "Malformed enrollment request.", nonce: n)
        }
        // 1. The device proves possession of the key it asks to enroll.
        let deviceFingerprint = KeyFingerprint.of(publicKeyDER: deviceKey)
        guard deviceFingerprint == auth.keyFingerprint,
              SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: deviceKey) else {
            securityLog("badsig-enroll", "Enrollment with invalid device signature rejected", "From \(request.remoteAddress).")
            return error(401, OriginErrorCode.invalidSignature, "The device signature does not verify.", nonce: n)
        }
        // 2. Fresh, never seen before.
        if let r = checkReplay(auth, from: request.remoteAddress) { return r }
        // 3. Meant for this gateway.
        guard body.gatewayFingerprint == identity.fingerprint else {
            return error(400, OriginErrorCode.wrongGateway, "This request is for a different gateway.", nonce: n)
        }
        // 4. A valid, active, unexpired invitation…
        guard let ii = state.invitations.firstIndex(where: { $0.id == body.invitationId }) else {
            securityLog("unknown-inv", "Unknown invitation", "\(body.device.name) from \(request.remoteAddress) used an invitation this gateway did not issue.")
            return error(404, OriginErrorCode.invitationUnknown, "This gateway did not issue that invitation.", nonce: n)
        }
        let invitation = state.invitations[ii]
        if invitation.status == .active && invitation.expiresAt <= clock() {
            state.invitations[ii].status = .expired
            pendingSecrets[invitation.id] = nil
            if activeInvitation?.id == invitation.id { activeInvitation = nil }
            persist()
        }
        switch state.invitations[ii].status {
        case .active: break
        case .expired:
            log(.pairing, .warning, "Expired invitation presented", "\(body.device.name) from \(request.remoteAddress) used \(invitation.id) after it expired.")
            return error(410, OriginErrorCode.invitationExpired, "The invitation has expired. Start pairing again in HCG Origin.", nonce: n)
        case .used:
            log(.security, .warning, "Used invitation presented again", "\(body.device.name) from \(request.remoteAddress) tried to reuse \(invitation.id).")
            return error(410, OriginErrorCode.invitationUsed, "The invitation was already used. Invitations are single use.", nonce: n)
        case .cancelled:
            return error(410, OriginErrorCode.invitationCancelled, "The invitation was cancelled.", nonce: n)
        }
        // 5. …whose secret the device holds (HMAC proof; the secret itself is never sent).
        guard let secret = pendingSecrets[invitation.id], InvitationCode.hashSecret(secret) == invitation.secretHash,
              let proof = auth.invitationProof,
              InvitationCode.verifyProof(proof, secret: secret, invitationId: invitation.id, signingInput: input.bytes) else {
            state.invitations[ii].failedProofs += 1
            var detail = "Attempt \(state.invitations[ii].failedProofs) of 5 from \(request.remoteAddress)."
            if state.invitations[ii].failedProofs >= 5 {
                state.invitations[ii].status = .cancelled
                pendingSecrets[invitation.id] = nil
                if activeInvitation?.id == invitation.id { activeInvitation = nil }
                detail += " The invitation was cancelled."
            }
            persist()
            log(.security, .warning, "Invalid invitation proof", detail)
            return error(401, OriginErrorCode.invalidInvitationProof, "The invitation proof is not valid.", nonce: n)
        }
        // 6. Single use from here on, whatever the outcome.
        state.invitations[ii].status = .used
        state.invitations[ii].usedAt = clock()
        state.invitations[ii].usedByFingerprint = deviceFingerprint
        pendingSecrets[invitation.id] = nil
        if activeInvitation?.id == invitation.id { activeInvitation = nil }

        // 7. Duplicate enrollment.
        if let existing = state.devices.first(where: { $0.fingerprint == deviceFingerprint && $0.status == .active }) {
            persist()
            log(.enrollment, .warning, "Duplicate enrollment refused", "\(body.device.name) is already enrolled as \(existing.id). The invitation was consumed.",
                deviceId: existing.id)
            return error(409, OriginErrorCode.alreadyEnrolled, "This device is already enrolled with this gateway as \(existing.id).", nonce: n)
        }
        if let blocked = state.devices.first(where: { $0.fingerprint == deviceFingerprint && $0.status == .blockedLocally }) {
            persist()
            return error(403, OriginErrorCode.deviceBlocked, "This device is blocked on this gateway (\(blocked.id)).", nonce: n)
        }
        if let open = state.requests.first(where: { $0.deviceFingerprint == deviceFingerprint && $0.isOpen }) {
            persist()
            log(.enrollment, .warning, "Duplicate enrollment request refused", "\(body.device.name) already has request \(open.id) awaiting a decision.",
                requestId: open.id)
            return error(409, OriginErrorCode.enrollmentPending, "A request from this device is already awaiting a decision.", nonce: n, requestId: open.id)
        }

        // 8. Screen capabilities: execution is never part of enrollment.
        let (forward, refused) = Capability.screen(body.requestedCapabilities)
        let now = clock()
        let requestId = Encoding.randomID(prefix: "req_")
        let check = PairingCheckCode.compute(gatewayFingerprint: identity.fingerprint, deviceFingerprint: deviceFingerprint, invitationId: invitation.id)
        let env = settings.centralMode.wireEnvironment
        let decider = settings.centralMode == .development ? "Local development service (not HCG)" : "HCG central verification"
        let record = EnrollmentRecord(
            id: requestId, invitationId: invitation.id, device: body.device, deviceFingerprint: deviceFingerprint,
            observedFrom: request.remoteAddress, requestedCapabilities: body.requestedCapabilities,
            forwardedCapabilities: forward, refusedCapabilities: refused, checkCode: check, receivedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(settings.requestTTLSeconds)), state: .received, environment: env,
            steps: [
                VerificationStep(id: "invitation", title: "Invitation valid and unused", result: .passed, detail: invitation.id, at: now),
                VerificationStep(id: "proof", title: "Invitation secret proven (HMAC)", result: .passed, detail: nil, at: now),
                VerificationStep(id: "signature", title: "Device key signature", result: .passed, detail: KeyFingerprint.short(deviceFingerprint), at: now),
                VerificationStep(id: "replay", title: "Fresh request (time window and nonce)", result: .passed, detail: nil, at: now),
                VerificationStep(id: "gateway", title: "Addressed to this gateway", result: .passed, detail: KeyFingerprint.short(identity.fingerprint), at: now),
                VerificationStep(id: "capabilities", title: "Capabilities screened", result: refused.isEmpty ? .passed : .failed,
                                 detail: refused.isEmpty ? "Forwarding \(forward.joined(separator: ", "))"
                                    : "Refused here: \(refused.map(\.capability).joined(separator: ", ")). Forwarding \(forward.isEmpty ? "nothing" : forward.joined(separator: ", ")).", at: now),
                VerificationStep(id: "central", title: "\(decider): account and device", result: .pending, detail: "Not yet submitted.", at: nil),
                VerificationStep(id: "decision", title: settings.centralMode == .development ? "Decision (development ERP page)" : "Decision by authorised person (ERP)",
                                 result: .pending, detail: nil, at: nil),
            ],
            forwarded: ForwardedDeviceRequest(method: request.method, path: request.path, timestamp: auth.timestamp, nonce: auth.nonce,
                                              keyFingerprint: auth.keyFingerprint, body: Encoding.base64url(request.body),
                                              signature: Encoding.base64url(auth.signature)),
            centralEnrollmentId: nil, centralState: nil, lastCentralError: nil, centralAttempts: 0, nextCentralAttemptAt: nil,
            decidedAt: nil, decisionReason: nil, issuedDeviceId: nil, grant: nil)
        state.requests.append(record)
        if state.requests.count > 300 { state.requests.removeFirst(state.requests.count - 300) }
        persist()
        log(.enrollment, .info, "Enrollment request received", "\(body.device.name) (\(body.device.platform), \(body.device.clientKind)) from \(request.remoteAddress). Check code \(check)."
            + (refused.isEmpty ? "" : " Refused: \(refused.map(\.capability).joined(separator: ", ")) — execution needs separate Agent Runtime authorisation."),
            requestId: requestId)
        Task { await self.syncCentral(force: true) }

        let response = EnrollResponseBody(
            requestId: requestId, state: .received, checkCode: check, gatewayName: settings.gatewayName,
            gatewayFingerprint: identity.fingerprint, gatewayPublicKey: identity.publicKeyBase64url, environment: env,
            forwardedCapabilities: forward, refusedCapabilities: refused,
            message: "Request received. It is being forwarded to \(decider). Possession of an invitation is not approval.")
        return respond(202, response, nonce: n)
    }

    func handleStatus(_ request: HTTPRequest, auth: SignedEnvelope.RequestAuth, input: RequestSigningInput) -> HTTPResponse {
        let n = auth.nonce
        guard let body = try? Wire.decoder().decode(EnrollmentStatusRequestBody.self, from: request.body),
              body.type == EnrollmentStatusRequestBody.typeValue else {
            return error(400, OriginErrorCode.badRequest, "Malformed status request.", nonce: n)
        }
        guard let record = state.requests.first(where: { $0.id == body.requestId }), record.deviceFingerprint == auth.keyFingerprint,
              let key = record.device.publicKeyDER else {
            return error(404, OriginErrorCode.unknownRequest, "No such request for this device.", nonce: n)
        }
        guard SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: key) else {
            securityLog("badsig-status", "Status request with invalid signature", "From \(request.remoteAddress).")
            return error(401, OriginErrorCode.invalidSignature, "The device signature does not verify.", nonce: n)
        }
        if let r = checkReplay(auth, from: request.remoteAddress) { return r }
        var central = record.centralState
        if record.state == .received {
            central = record.lastCentralError != nil ? "unreachable" : "submitting"
        }
        let message: String
        switch record.state {
        case .received: message = record.lastCentralError.map { "Waiting for the central service: \($0)" } ?? "Being forwarded for verification."
        case .awaitingDecision: message = "Waiting for the authorised person to decide."
        case .approved: message = "Approved. Connect with the granted capabilities only."
        case .rejected: message = "Rejected" + (record.decisionReason.map { ": \($0)" } ?? ".")
        case .expired: message = "Expired without a decision. Ask for a new invitation."
        case .failed: message = "Could not be processed" + (record.decisionReason.map { ": \($0)" } ?? ".")
        }
        // A device approved but later revoked must not learn a usable grant.
        var grant = record.grant
        var deviceId = record.issuedDeviceId
        if record.state == .approved, let d = state.devices.first(where: { $0.id == record.issuedDeviceId }), d.status != .active {
            grant = nil
            deviceId = d.id
        }
        return respond(200, EnrollmentStatusResponseBody(requestId: record.id, state: record.state, centralState: central,
                                                         reason: record.decisionReason, deviceId: deviceId, grant: grant,
                                                         environment: record.environment, message: message), nonce: n)
    }

    func handleHeartbeat(_ request: HTTPRequest, auth: SignedEnvelope.RequestAuth, input: RequestSigningInput) -> HTTPResponse {
        let n = auth.nonce
        guard let i = state.devices.firstIndex(where: { $0.fingerprint == auth.keyFingerprint }),
              let key = Encoding.fromBase64url(state.devices[i].publicKey) else {
            securityLog("unknown-dev", "Connection from unknown device rejected", "Key \(KeyFingerprint.short(auth.keyFingerprint)) from \(request.remoteAddress) is not enrolled.")
            return error(401, OriginErrorCode.unknownDevice, "This device is not enrolled with this gateway.", nonce: n)
        }
        guard SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: key) else {
            securityLog("badsig-hb", "Connection with invalid signature rejected", "From \(request.remoteAddress).")
            return error(401, OriginErrorCode.invalidSignature, "The device signature does not verify.", nonce: n)
        }
        if let r = checkReplay(auth, from: request.remoteAddress) { return r }
        guard let body = try? Wire.decoder().decode(HeartbeatRequestBody.self, from: request.body),
              body.type == HeartbeatRequestBody.typeValue, body.deviceId == state.devices[i].id else {
            return error(400, OriginErrorCode.badRequest, "Malformed connection request.", nonce: n)
        }
        let device = state.devices[i]
        let now = clock()
        func rejectLogged(_ title: String) {
            if device.lastRejectedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                state.devices[i].lastRejectedAt = now
                log(.connection, .warning, title, "\(device.name) from \(request.remoteAddress).", deviceId: device.id)
                persist()
            }
        }
        switch device.status {
        case .revoked:
            rejectLogged("Connection from revoked device refused")
            return error(403, OriginErrorCode.deviceRevoked, "Access for this device was revoked" + (device.statusReason.map { ": \($0)" } ?? "."), nonce: n)
        case .blockedLocally:
            rejectLogged("Connection from blocked device refused")
            return error(403, OriginErrorCode.deviceBlocked, "This device is blocked on this gateway.", nonce: n)
        case .active: break
        }
        guard device.environment == settings.centralMode.wireEnvironment else {
            return error(403, "environment_inactive", "This device was enrolled in the \(device.environment) environment, which this gateway is not using now.", nonce: n)
        }
        guard device.grant.allows(Capability.presence) else {
            return error(403, OriginErrorCode.capabilityNotGranted, "connection.presence was not granted.", nonce: n)
        }
        if body.report != nil && !device.grant.allows(Capability.statusReport) {
            return error(403, OriginErrorCode.capabilityNotGranted, "device.status.report was not granted; send heartbeats without a report.", nonce: n)
        }
        let previous = device.connectionState(now: now, disconnectAfter: disconnectAfter)
        state.devices[i].lastContactAt = now
        state.devices[i].lastContactFrom = request.remoteAddress
        state.devices[i].lastSequence = body.sequence
        if let report = body.report { state.devices[i].lastReport = report }
        if previous != .connected {
            let reconnect = previous == .disconnected
            state.devices[i].connectedSince = now
            log(.connection, .success, reconnect ? "Device reconnected" : "Device connected",
                "\(device.name) from \(request.remoteAddress) with \(device.grant.capabilities.joined(separator: ", ")).", deviceId: device.id)
            queueEvent(reconnect ? "gateway.device.reconnected" : "gateway.device.connected", deviceId: device.id, detail: request.remoteAddress)
        }
        knownConnection[device.id] = .connected
        persist()
        return respond(200, HeartbeatResponseBody(state: "connected", grant: state.devices[i].grant,
                                                   intervalSeconds: settings.heartbeatIntervalSeconds, serverTime: now), nonce: n)
    }
}

import Foundation
import HCGOriginProtocol

extension GatewayEngine {
    static let serverTokenName = "hcg-server-admin-token"

    func serverClient() -> HCGServerAdminClient? {
        guard let conn = settings.hcgServer,
              let data = try? secrets.read(Self.serverTokenName), let token = String(data: data, encoding: .utf8) else { return nil }
        return try? HCGServerAdminClient(adminURL: conn.adminURL, token: token)
    }

    /// Connects Origin to HCG Server's owner API (loopback). Verifies the connection with a real request before
    /// storing anything; the owner token is kept only in Origin's secret store (Keychain on macOS).
    public func connectHCGServer(adminURL: String, token: String, source: String) async throws {
        try await require(.serverConnect)
        let client = try HCGServerAdminClient(adminURL: adminURL, token: token)
        let device = try await client.device()
        let link = try await client.linkStatus()
        try secrets.write(Self.serverTokenName, Data(token.utf8))
        updateSettings { $0.hcgServer = HCGServerConnection(adminURL: client.baseURL.absoluteString, source: source) }
        serverState.connection = settings.hcgServer
        serverState.device = device.device
        serverState.link = link
        log(.gateway, .success, "Connected to HCG Server",
            "\(device.device.name) (\(device.device.platform ?? "?"), agent \(device.device.agentVersion ?? "?"), key \(KeyFingerprint.short(device.device.fingerprint))) at \(client.baseURL.absoluteString) — by \(attribution()). Device Link \(link.configured == true ? "configured" : "not configured").")
        queueEvent("gateway.server.connected", detail: "HCG Server \(device.device.deviceId) by \(attributedOwner?.accountId ?? "local owner")")
        persist()
        await syncHCGServer(force: true)
    }

    /// Connects to the HCG Server agent on this Mac using its runtime file and its Keychain token (macOS asks first).
    public func connectLocalHCGServer() async throws {
        guard let rt = HCGServerLocator.runtime() else {
            throw HCGServerError.notFound("HCG Server is not running on this Mac (no runtime.json in \(HCGServerLocator.defaultDataDirectory().path)). Start HCG Server, or paste its admin link.")
        }
        #if os(macOS)
        let token = try HCGServerLocator.keychainToken()
        try await connectHCGServer(adminURL: "http://\(rt.adminAddress)", token: token, source: "runtime.json")
        #else
        throw HCGServerError.notFound("Reading HCG Server's token from the Keychain is available on macOS only; paste the admin link instead.")
        #endif
    }

    public func disconnectHCGServer() {
        try? secrets.delete(Self.serverTokenName)
        updateSettings { $0.hcgServer = nil }
        serverState = .empty
        log(.gateway, .info, "Disconnected from HCG Server", "The owner token was removed from Origin's secret store by \(attribution()). HCG Server itself is unchanged.")
        queueEvent("gateway.server.disconnected", detail: "by \(attributedOwner?.accountId ?? "local owner")")
        persist()
        notify()
    }

    func syncHCGServer(force: Bool = false) async {
        guard settings.hcgServer != nil else {
            if serverState.connection != nil { serverState = .empty }
            return
        }
        let now = clock()
        if serverSyncing { return }
        if !force, let last = lastServerSync, now.timeIntervalSince(last) < TimeInterval(max(2, settings.centralSyncSeconds)) { return }
        serverSyncing = true
        lastServerSync = now
        defer { serverSyncing = false }
        serverState.connection = settings.hcgServer
        guard let client = serverClient() else {
            serverState.reachability = .unauthorized
            serverState.lastError = "No owner token for HCG Server. Reconnect in Settings."
            return
        }
        do {
            let health = try await client.health()
            let device = try await client.device()
            let link = try await client.linkStatus()
            let pairings = try await client.pairings()
            let installations = try await client.installations()
            let wasReachable: Bool = { if case .reachable = serverState.reachability { return true }; return false }()
            if !wasReachable && serverState.lastSyncAt != nil {
                log(.connection, .success, "HCG Server reachable again", "\(device.device.name) at \(client.baseURL.absoluteString).")
            }
            noteServerChanges(old: serverState, newPairings: pairings, newInstallations: installations)
            serverState.health = health
            serverState.device = device.device
            serverState.link = link
            serverState.pairings = pairings.sorted { $0.receivedAt > $1.receivedAt }
            serverState.installations = installations.sorted { $0.pairedAt > $1.pairedAt }
            serverState.reachability = .reachable(at: clock())
            serverState.lastSyncAt = clock()
            serverState.lastError = nil
        } catch let e as HCGServerError {
            serverState.lastError = e.description
            if case .unauthorized = e {
                serverState.reachability = .unauthorized
            } else if case .unreachable(_, let since) = serverState.reachability {
                serverState.reachability = .unreachable(e.description, since: since)
            } else {
                serverState.reachability = .unreachable(e.description, since: clock())
                log(.connection, .error, "HCG Server unreachable", e.description + " Origin keeps retrying.")
                queueEvent("gateway.server.unreachable", detail: e.description)
            }
        } catch {
            serverState.lastError = "\(error)"
        }
    }

    /// Activity for changes HCG Server reports (new requests, presence), so the log shows what happened when.
    func noteServerChanges(old: HCGServerSnapshot, newPairings: [LinkPairingInfo], newInstallations: [LinkInstallationInfo]) {
        guard old.lastSyncAt != nil else { return } // first sync: no change history yet
        let known = Set(old.pairings.map(\.requestId))
        for p in newPairings where !known.contains(p.requestId) && p.status == "pending" {
            log(.enrollment, .info, "Device Link pairing request received",
                "\(p.installation.name) (\(p.installation.app) \(p.installation.appVersion), \(p.installation.platform)) for \(p.account.email ?? p.account.subject), key \(KeyFingerprint.short(p.keyFingerprint)). HCG Server verified the signature, HCG Connect token and ERP permission; waiting for your review.")
        }
        let before = Dictionary(old.installations.map { ($0.installationId, $0.state) }, uniquingKeysWith: { a, _ in a })
        for i in newInstallations {
            guard let prev = before[i.installationId], prev != i.state else { continue }
            switch i.state {
            case "online": log(.connection, .success, "Device Link device online", "\(i.name) (\(i.app)).")
            case "offline": log(.connection, .warning, "Device Link device offline", "\(i.name) (\(i.app)): no contact within HCG Server's presence window.")
            case "revoked": log(.revocation, .warning, "Device Link device revoked", "\(i.name) (\(i.app)) by \(i.revokedBy ?? "?").")
            default: break
            }
        }
    }

    /// Creates a single-use HCG Server pairing invitation (`hcg1-…`) for one device.
    public func createServerInvitation(ttlSeconds: Int = 600) async throws -> HCGServerInvitation {
        try await require(.devicesEnroll)
        guard let client = serverClient() else { throw HCGServerError.notFound("Connect HCG Server first.") }
        let inv = try await client.createInvitation(ttlSeconds: ttlSeconds)
        serverState.lastInvitation = inv
        log(.pairing, .info, "HCG Server invitation created", "\(inv.id), valid until \(Self.timeFormatter.string(from: inv.expiresAt)), by \(attribution()). Single use.")
        queueEvent("gateway.server.invitation_created", detail: "\(inv.id) by \(attributedOwner?.accountId ?? "local owner")")
        persist()
        notify()
        return inv
    }

    /// Approves a Device Link pairing on HCG Server. Requires: a signed-in owner (attribution), the central
    /// `origin.requests.review` permission, and the key fingerprint the owner compared with the device.
    public func approveServerPairing(requestId: String, confirmedFingerprint: String) async throws {
        guard let owner = attributedOwner else {
            throw PermissionError.denied(PermissionDecision(feature: .requestsReview, allowed: false, reason: "not_signed_in", layer: "identity", at: clock(), source: "local"))
        }
        try await require(.requestsReview)
        guard let client = serverClient() else { throw HCGServerError.notFound("Connect HCG Server first.") }
        let pairings = try await client.pairings()
        guard let p = pairings.first(where: { $0.requestId == requestId }) else { throw HCGServerError.notFound("No such pairing request on HCG Server.") }
        guard p.status == "pending" else { throw HCGServerError.notFound("The request is \(p.status); only pending requests can be approved.") }
        guard p.keyFingerprint.lowercased() == confirmedFingerprint.lowercased() else {
            log(.security, .warning, "Approval refused: fingerprint not confirmed", "\(p.installation.name): the confirmed fingerprint does not match the request.")
            throw HCGServerError.notFound("The confirmed key fingerprint does not match this request. Nothing was approved.")
        }
        let inst = try await client.approve(requestId: requestId)
        log(.decision, .success, "Device Link pairing approved",
            "\(inst.name) (\(inst.app) \(inst.appVersion)) for \(p.account.email ?? p.account.subject), key \(KeyFingerprint.short(p.keyFingerprint)) — approved by \(owner.email) on this Mac. Remote actions stay disabled.",
            deviceId: inst.installationId, requestId: requestId)
        queueEvent("gateway.server.pairing_approved", deviceId: inst.installationId, requestId: requestId,
                   detail: "\(inst.app) for \(p.account.subject) approved by \(owner.accountId)")
        persist()
        await syncHCGServer(force: true)
        notify()
    }

    public func rejectServerPairing(requestId: String) async throws {
        _ = try await requireForReduction(.requestsReview)
        guard let client = serverClient() else { throw HCGServerError.notFound("Connect HCG Server first.") }
        try await client.reject(requestId: requestId)
        log(.decision, .warning, "Device Link pairing rejected", "Request \(requestId) rejected by \(attribution()).", requestId: requestId)
        queueEvent("gateway.server.pairing_rejected", requestId: requestId, detail: "rejected by \(attributedOwner?.accountId ?? "local owner")")
        persist()
        await syncHCGServer(force: true)
        notify()
    }

    public func revokeServerInstallation(installationId: String) async throws {
        _ = try await requireForReduction(.gatewayManage)
        guard let client = serverClient() else { throw HCGServerError.notFound("Connect HCG Server first.") }
        let name = serverState.installations.first { $0.installationId == installationId }?.name ?? installationId
        try await client.revoke(installationId: installationId)
        log(.revocation, .warning, "Device Link device revoked", "\(name) revoked on HCG Server by \(attribution()). Its next request is refused (device_revoked).",
            deviceId: installationId)
        queueEvent("gateway.server.installation_revoked", deviceId: installationId, detail: "revoked by \(attributedOwner?.accountId ?? "local owner")")
        persist()
        await syncHCGServer(force: true)
        notify()
    }
}

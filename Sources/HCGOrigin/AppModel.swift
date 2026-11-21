import SwiftUI
import AppKit
import ServiceManagement
import AuthenticationServices
import HCGOriginCore
import HCGOriginProtocol

enum AppSection: String, CaseIterable, Identifiable {
    case overview, requests, devices, activity, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .requests: return "Connection Requests"
        case .devices: return "Devices"
        case .activity: return "Activity"
        case .settings: return "Account & Settings"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .requests: return "person.badge.key"
        case .devices: return "laptopcomputer.and.iphone"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct BuildInfo {
    let version: String
    let build: String
    let commit: String
    let builtAt: String
    let automation: Bool

    static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        #if HCG_UI_AUTOMATION
        let automation = true
        #else
        let automation = false
        #endif
        return BuildInfo(version: info["CFBundleShortVersionString"] as? String ?? OriginVersion.marketing,
                         build: info["CFBundleVersion"] as? String ?? "dev",
                         commit: info["HCGSourceCommit"] as? String ?? "uncommitted (swift run)",
                         builtAt: info["HCGBuildDate"] as? String ?? "-",
                         automation: automation)
    }()

    var summary: String { "Version \(version) (\(build)) · commit \(commit)" + (automation ? " · UI-automation build" : "") }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: GatewaySnapshot?
    @Published var section: AppSection = .overview
    @Published var selectedRequestId: String?
    @Published var selectedDeviceId: String?
    @Published var showPairing = false
    @Published var notice: String?
    @Published var busy = false
    @Published var loginItemStatus: String = ""

    let engine: GatewayEngine
    let build = BuildInfo.current
    private var webAuth: WebAuthenticator?

    init() {
        let production = ProductionConfiguration.fromInfoDictionary(Bundle.main.infoDictionary)
        let store: SecretStore
        let service = ProcessInfo.processInfo.environment["HCG_ORIGIN_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? "HCG Origin"
        if ProcessInfo.processInfo.environment["HCG_ORIGIN_DEV_FILE_SECRETS"] == "1" {
            store = FileSecretStore(url: OriginPaths.dataDirectory().appendingPathComponent("dev-secrets.json"))
        } else if let service = ProcessInfo.processInfo.environment["HCG_ORIGIN_KEYCHAIN_SERVICE"], !service.isEmpty {
            store = KeychainSecretStore(service: service) // isolated items for verification runs
        } else {
            store = KeychainSecretStore()
        }
        // Connector traffic always uses TLS 1.3 with the gateway's pinned certificate. There is no
        // cleartext fallback in the app: if the certificate cannot be prepared, the listener fails.
        engine = GatewayEngine(dataDirectory: OriginPaths.dataDirectory(), secrets: store, production: production,
                               hostName: Host.current().localizedName ?? "This Mac",
                               transport: .tls(label: GatewayTLSIdentity.label(forService: service)))
        refreshLoginItemStatus()
        let engine = self.engine
        let sink: @Sendable (GatewaySnapshot) -> Void = { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        Task {
            await engine.setObserver(sink)
            await engine.start()
        }
    }

    private func apply(_ snap: GatewaySnapshot) {
        snapshot = snap
        if showPairing, snap.activeInvitation == nil, pairingWasActive {
            pairingWasActive = false
        }
        if snap.activeInvitation != nil { pairingWasActive = true }
    }
    private var pairingWasActive = false

    // MARK: Actions

    func run(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                notice = nil
            } catch {
                notice = "\(label): \(error)"
            }
        }
    }

    func startPairing() {
        run("Pairing") { [engine] in
            _ = try await engine.startPairing()
            await MainActor.run { self.showPairing = true }
        }
    }

    func cancelPairing() {
        Task { await engine.cancelPairing() }
        showPairing = false
    }

    func syncNow() { Task { await engine.syncNow() } }

    func setMode(_ mode: CentralMode) { Task { await engine.updateSettings { $0.centralMode = mode } } }

    func update(_ change: @escaping @Sendable (inout OriginSettings) -> Void) { Task { await engine.updateSettings(change) } }

    func signInDevelopment(email: String, name: String) {
        run("Development sign-in") { [engine] in try await engine.signInDevelopment(email: email, displayName: name) }
    }

    func signOut() { Task { await engine.signOut() } }

    func block(_ id: String) { Task { await engine.blockDeviceLocally(id: id) } }
    func unblock(_ id: String) { Task { await engine.unblockDevice(id: id) } }
    func removeRecord(_ id: String) { Task { await engine.removeDeviceRecord(id: id) } }
    func dismissRequest(_ id: String) { Task { await engine.dismissRequest(id: id) } }
    func restartListener() { Task { await engine.restartListener() } }
    func retryListener() { Task { await engine.retryListener() } }
    func runSelfTest() { Task { await engine.runSelfTest() } }

    func moveToFreePort() {
        Task {
            if await engine.moveToFreePort() == nil {
                await MainActor.run { self.notice = "No free port in 47700–47719 on this Mac." }
            }
        }
    }

    func copyDiagnostics() {
        Task {
            let report = await engine.diagnosticsReport()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }

    /// Brings the copy of HCG Origin that owns the gateway to the front (when another copy holds it).
    func switchToRunningCopy(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    /// HCG Connect sign-in (system browser, PKCE). Only reachable when every production value is configured.
    func signInWithHCGConnect() {
        guard let p = snapshot?.production, p.isComplete else { return }
        run("HCG Connect sign-in") { [engine] in
            let discovery = try await HCGConnectPKCE.discover(issuer: p.hcgConnectIssuer)
            let verifier = HCGConnectPKCE.newVerifier()
            let state = Encoding.base64url(Encoding.randomBytes(16))
            guard let url = HCGConnectPKCE.authorizeURL(discovery: discovery, clientID: p.hcgConnectClientID,
                                                        redirectURI: p.hcgConnectRedirectURI, state: state,
                                                        challenge: HCGConnectPKCE.challenge(for: verifier)),
                  let scheme = URL(string: p.hcgConnectRedirectURI)?.scheme else {
                throw CentralError.malformed("could not build the sign-in request")
            }
            let callback = try await self.authenticate(url: url, scheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw CentralError.unauthorized("the sign-in response did not match this request")
            }
            let tokens = try await HCGConnectPKCE.exchange(code: code, verifier: verifier, discovery: discovery,
                                                           clientID: p.hcgConnectClientID, redirectURI: p.hcgConnectRedirectURI)
            try await engine.completeProductionSignIn(accessToken: tokens.access_token)
        }
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let auth = WebAuthenticator()
            self.webAuth = auth
            auth.start(url: url, scheme: scheme) { result in continuation.resume(with: result) }
        }
    }

    // MARK: Open at login (explicit setting, visible status)

    func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "On — HCG Origin opens when you log in."
        case .requiresApproval: loginItemStatus = "Waiting for approval in System Settings → General → Login Items."
        case .notRegistered: loginItemStatus = "Off"
        case .notFound: loginItemStatus = "Unavailable for this copy of the app (move it to Applications first)."
        @unknown default: loginItemStatus = "Unknown"
        }
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Open at login: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }
}

final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
            if let callback { completion(.success(callback)) }
            else { completion(.failure(error ?? CentralError.unauthorized("sign-in was cancelled"))) }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

enum Fmt {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f }()
    static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f }()
    static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        if abs(now.timeIntervalSince(date)) < 5 { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func capability(_ id: String) -> String { Capability.info(id)?.title ?? id }
}

extension EnrollmentState {
    var label: String {
        switch self {
        case .received: return "Received"
        case .awaitingDecision: return "Awaiting decision"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .expired: return "Expired"
        case .failed: return "Failed"
        }
    }
    var tone: Tone {
        switch self {
        case .received, .awaitingDecision: return .warn
        case .approved: return .ok
        case .rejected, .failed: return .err
        case .expired: return .neutral
        }
    }
}

extension ConnectionState {
    var label: String {
        switch self {
        case .awaitingFirstContact: return "Awaiting first contact"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .revoked: return "Revoked"
        case .blocked: return "Blocked here"
        }
    }
    var tone: Tone {
        switch self {
        case .connected: return .ok
        case .awaitingFirstContact: return .info
        case .disconnected: return .warn
        case .revoked, .blocked: return .err
        }
    }
}

extension ActivitySeverity {
    var tone: Tone {
        switch self { case .info: return .info; case .success: return .ok; case .warning: return .warn; case .error: return .err }
    }
}

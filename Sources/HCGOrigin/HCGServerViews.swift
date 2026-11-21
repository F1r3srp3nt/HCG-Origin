import SwiftUI
import HCGOriginCore
import HCGOriginProtocol

enum ServerText {
    static func reachability(_ r: HCGServerReachability) -> (String, Tone) {
        switch r {
        case .notConnected: return ("Not connected", .neutral)
        case .reachable: return ("Connected", .ok)
        case .unreachable: return ("Unreachable", .err)
        case .unauthorized: return ("Owner token not accepted", .err)
        }
    }
    static func presenceTone(_ state: String) -> Tone {
        switch state {
        case "online": return .ok
        case "offline": return .warn
        case "revoked": return .err
        default: return .info
        }
    }
}

/// Overview: HCG Server status.
struct HCGServerPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        let reach = ServerText.reachability(s.server.reachability)
        let label = reach.0
        let tone = reach.1
        Panel("HCG Server") {
            HStack(spacing: 10) {
                StatusDot(tone: tone, pulsing: tone == .ok)
                Text(label).font(.headline)
                Spacer()
                Badge(text: "DEVICE LINK", tone: .info)
            }
            if let d = s.server.device {
                FieldRow(label: "Server", value: "\(d.name) · \(d.platform ?? "?") · agent \(d.agentVersion ?? "?")")
                FieldRow(label: "Server key", value: KeyFingerprint.short(d.fingerprint), mono: true)
            }
            if let link = s.server.link {
                FieldRow(label: "Device Link", value: link.configured == true
                         ? "Configured · apps: \((link.trustedApps ?? []).joined(separator: ", "))"
                         : "Not configured — \(link.configError ?? "missing HCG Connect clients or permission mappings")")
                FieldRow(label: "Remote actions", value: link.actionsEnabled == true ? "ENABLED on the server" : "Disabled (no action registry)")
            }
            FieldRow(label: "Pending requests", value: "\(s.server.pendingPairings.count)")
            FieldRow(label: "Devices", value: "\(s.server.installations.filter { $0.state != "revoked" }.count) active · \(s.server.installations.filter { $0.state == "online" }.count) online")
            if let e = s.server.lastError { Text(e).font(.caption).foregroundStyle(HCG.err).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if s.server.connection == nil {
                    Button("Connect HCG Server…") { model.section = .settings }.hcgButton()
                } else {
                    Button("Review Requests") { model.section = .requests }.hcgButton()
                }
            }
        }
    }
}

/// Connection Requests: HCG Server Device Link requests.
struct ServerRequestsSection: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    @State private var confirming: LinkPairingInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HCG SERVER DEVICE LINK").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(HCG.textFaint)
                Spacer()
                Button("New HCG Server Invitation") { model.createServerInvitation() }.hcgButton()
                    .disabled(s.server.connection == nil || model.busy)
            }
            if s.server.connection == nil {
                Text("Not connected to HCG Server. Connect it in Account & Settings to review its Device Link requests here.")
                    .font(.callout).foregroundStyle(HCG.textDim)
            } else if s.server.pairings.isEmpty {
                Text("No Device Link requests. Create an HCG Server invitation and enter it in HCG Sentinel or HCG Terminal.")
                    .font(.callout).foregroundStyle(HCG.textDim)
            }
            if let code = model.serverInvitationCode {
                Panel("HCG Server invitation (single use, 10 minutes)") {
                    HStack(alignment: .top, spacing: 16) {
                        QRCodeView(text: code).frame(width: 150, height: 150).padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(code).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).lineLimit(6)
                            HStack {
                                Button("Copy Code") {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                                }.hcgButton()
                                Button("Hide") { model.serverInvitationCode = nil }.hcgButton()
                            }
                        }
                    }
                }
            }
            ForEach(s.server.pairings) { p in
                ServerPairingRow(p: p, now: s.now, approve: { confirming = p }, reject: { model.rejectServerPairing(p) })
            }
        }
        .confirmationDialog("Approve this device?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { p in
            Button("The device shows \(KeyFingerprint.short(p.keyFingerprint)) — Approve") { model.approveServerPairing(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("\(p.installation.name) (\(p.installation.app)) for \(p.account.email ?? p.account.subject).\nCompare this key fingerprint with the one shown on the device:\n\(p.keyFingerprint)\nApproval is recorded in your name. Remote actions stay disabled.")
        }
    }
}

struct ServerPairingRow: View {
    let p: LinkPairingInfo
    let now: Date
    let approve: () -> Void
    let reject: () -> Void
    var body: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.installation.name).font(.headline)
                    Text("\(p.installation.app) \(p.installation.appVersion)\(p.installation.variant.map { " · \($0)" } ?? "") · \(p.installation.platform)")
                        .font(.caption).foregroundStyle(HCG.textDim)
                    Text("HCG account (verified by HCG Server): \(p.account.email ?? p.account.subject)").font(.caption).foregroundStyle(HCG.textDim)
                    Text("Key \(KeyFingerprint.short(p.keyFingerprint)) · from \(p.observedFrom) · \(Fmt.ago(p.receivedAt, now: now))")
                        .font(HCG.monoSmall).foregroundStyle(HCG.textFaint)
                }
                Spacer()
                Badge(text: p.status.uppercased(), tone: p.status == "pending" ? .warn : (p.status == "approved" ? .ok : .err))
            }
            if p.status == "pending" {
                HStack {
                    Button("Review and Approve…", action: approve).hcgPrimaryButton()
                    Button("Reject", action: reject).hcgButton()
                    Spacer()
                    Text("Expires \(Fmt.ago(p.expiresAt, now: now))").font(.caption).foregroundStyle(HCG.textFaint)
                }
            }
        }
    }
}

/// Devices: HCG Server Device Link inventory.
struct ServerDevicesSection: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HCG SERVER DEVICE LINK").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(HCG.textFaint)
            if s.server.installations.isEmpty {
                Text(s.server.connection == nil ? "Not connected to HCG Server." : "No devices paired with HCG Server.")
                    .font(.callout).foregroundStyle(HCG.textDim)
            }
            ForEach(s.server.installations) { i in
                Panel {
                    HStack(alignment: .top) {
                        StatusDot(tone: ServerText.presenceTone(i.state), pulsing: i.state == "online")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(i.name).font(.headline)
                            Text("\(i.app) \(i.appVersion) · \(i.platform) · \(i.account.email ?? i.account.subject)").font(.caption).foregroundStyle(HCG.textDim)
                            Text("Key \(KeyFingerprint.short(i.keyFingerprint)) · last seen \(Fmt.ago(i.lastSeenAt, now: s.now))").font(HCG.monoSmall).foregroundStyle(HCG.textFaint)
                            if let caps = i.capabilities, !caps.isEmpty {
                                Text("Advertised: " + caps.map { "\($0.id) (\($0.state))" }.joined(separator: ", ")).font(.caption2).foregroundStyle(HCG.textFaint)
                            }
                        }
                        Spacer()
                        Badge(text: i.state.uppercased(), tone: ServerText.presenceTone(i.state))
                    }
                    if i.state != "revoked" {
                        Button("Revoke on HCG Server") { model.revokeServerInstallation(i) }.hcgButton()
                    }
                }
            }
        }
    }
}

/// Settings: HCG Server connection and central permissions.
struct HCGServerSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    @State private var link = ""
    var body: some View {
        Panel("HCG Server") {
            FieldRow(label: "Status", value: ServerText.reachability(s.server.reachability).0)
            if let c = s.server.connection {
                FieldRow(label: "Owner API", value: "\(c.adminURL) (\(c.source == "runtime.json" ? "found on this Mac" : "pasted link"))", mono: true)
                Button("Disconnect") { model.disconnectHCGServer() }.hcgButton()
            } else {
                Text("Origin manages HCG Server's Device Link through HCG Server's owner API on this Mac (127.0.0.1). Connecting reads HCG Server's owner token from the Keychain — macOS asks you first — and keeps it only in Origin's Keychain items.")
                    .font(.caption).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Connect to HCG Server on This Mac") { model.connectLocalHCGServer() }.hcgPrimaryButton()
                }
                HStack {
                    SecureField("or paste the link from `hcg-agent admin-url`", text: $link).textFieldStyle(.roundedBorder)
                    Button("Connect") { model.connectHCGServer(link: link); link = "" }.hcgButton().disabled(link.isEmpty)
                }
            }
        }
    }
}

struct PermissionsPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        Panel("Central permissions (ERP App Access)") {
            Text("Each sensitive action asks HCG with your own session. Only an explicit allow permits it; outages refuse (except removing access). Command execution is disabled in this build regardless of licence or role.")
                .font(.caption).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
            ForEach(OriginFeature.allCases, id: \.self) { f in
                let d = s.permissions[f]
                HStack(spacing: 8) {
                    Image(systemName: d?.allowed == true ? "checkmark.circle.fill" : (d == nil ? "circle.dashed" : "xmark.circle"))
                        .foregroundStyle(d?.allowed == true ? HCG.ok : (d == nil ? HCG.textFaint : HCG.err))
                    Text(f.title)
                    Text(f.rawValue).font(HCG.monoSmall).foregroundStyle(HCG.textFaint)
                    Spacer()
                    Text(d.map { $0.allowed ? "allowed" : $0.reason } ?? "not checked").font(.caption).foregroundStyle(HCG.textDim)
                }
            }
            Button("Check Now") { model.refreshPermissions() }.hcgButton()
        }
    }
}

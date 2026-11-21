import SwiftUI
import HCGOriginCore
import HCGOriginProtocol

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Overview", subtitle: "Gateway status, central connection and enrolled devices on this Mac.",
                              trailing: AnyView(PairingButton(s: s)))
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        MetricTile(label: "Connected", value: "\(s.connectedCount)",
                                   detail: "Authenticated contact in the last \(s.settings.disconnectAfterSeconds) s",
                                   tone: s.connectedCount > 0 ? .ok : .neutral)
                        MetricTile(label: "Enrolled", value: "\(s.enrolledCount)", detail: "Admitted and not revoked")
                        MetricTile(label: "Pending requests", value: "\(s.openRequestCount)",
                                   detail: "Awaiting central verification or a decision", tone: s.openRequestCount > 0 ? .warn : .neutral)
                        MetricTile(label: "Revoked / blocked", value: "\(s.revokedCount)", detail: "Origin rejects all their requests",
                                   tone: s.revokedCount > 0 ? .err : .neutral)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        GatewayPanel(s: s)
                        CentralPanel(s: s)
                    }
                    if case .unavailable(let reason) = s.pairing {
                        Panel("Pairing") {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "lock.fill").foregroundStyle(HCG.warn)
                                Text(reason).font(.callout).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Panel("Recent activity") {
                        if s.activity.isEmpty {
                            Text("No activity yet.").foregroundStyle(HCG.textDim)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(s.activity.prefix(6))) { e in
                                    ActivityRow(entry: e, now: s.now, compact: true)
                                    if e.id != s.activity.prefix(6).last?.id { Divider().overlay(HCG.edge) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
    }
}

struct PairingButton: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        if s.activeInvitation != nil {
            Button { model.section = .requests; model.showPairing = true } label: {
                Label("Pairing in progress", systemImage: "qrcode")
            }.hcgButton()
        } else {
            Button { model.section = .requests; model.startPairing() } label: {
                Label("Start Pairing", systemImage: "plus.viewfinder")
            }
            .hcgPrimaryButton()
            .disabled(s.pairing != .available || model.busy)
            .help(pairingHelp)
        }
    }
    var pairingHelp: String {
        if case .unavailable(let r) = s.pairing { return r }
        return "Create a short-lived, single-use invitation for one device."
    }
}

struct GatewayPanel: View {
    let s: GatewaySnapshot
    var body: some View {
        Panel("Gateway") {
            HStack(spacing: 10) {
                StatusDot(tone: tone, pulsing: tone == .ok)
                Text(title).font(.headline)
            }
            FieldRow(label: "Name", value: s.settings.gatewayName)
            FieldRow(label: "Listening", value: address)
            FieldRow(label: "Reachable from", value: s.settings.allowLocalNetwork ? "Local network (explicitly enabled)" : "This Mac only")
            FieldRow(label: "Key fingerprint", value: KeyFingerprint.short(s.gatewayFingerprint), mono: true)
            FieldRow(label: "Gateway ID", value: s.registration?.gatewayId ?? "Not issued — proposed \(s.proposedGatewayId)", mono: true)
            FieldRow(label: "Transport", value: TransportText.summary(s.transport))
            if let fp = s.transport?.tlsFingerprint {
                FieldRow(label: "TLS key (pinned)", value: KeyFingerprint.short(fp), mono: true)
            }
        }
    }
    var tone: Tone { switch s.listener { case .listening: return .ok; case .stopped: return .neutral; case .failed: return .err } }
    var title: String {
        switch s.listener {
        case .listening: return "Running"
        case .stopped: return "Stopped"
        case .failed: return "Listener failed"
        }
    }
    var address: String {
        switch s.listener {
        case .listening(let a, _): return a
        case .stopped: return "—"
        case .failed(let e): return e
        }
    }
}

struct CentralPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        Panel("Central connection") {
            HStack(spacing: 10) {
                StatusDot(tone: CentralText.tone(s.central.reachability))
                Text(CentralText.short(s)).font(.headline)
                Spacer()
                Badge(text: s.isDevelopment ? "LOCAL DEV SERVICE" : "PRODUCTION HCG", tone: s.isDevelopment ? .dev : .info)
            }
            Text(CentralText.detail(s)).font(.caption).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
            FieldRow(label: "Service", value: s.central.serviceURL ?? "Not configured", mono: true)
            FieldRow(label: "Signed in", value: s.account.map { "\($0.email)\(s.isDevelopment ? " (development account)" : "")" } ?? "No")
            FieldRow(label: "Last sync", value: Fmt.ago(s.central.lastSyncAt, now: s.now))
            if let e = s.central.lastError {
                FieldRow(label: "Last error", value: e)
            }
            HStack {
                Button("Sync now") { model.syncNow() }.hcgButton()
                    .disabled(s.central.serviceURL == nil)
                Button("Account & Settings") { model.section = .settings }.hcgButton()
            }
        }
    }
}

enum TransportText {
    static func summary(_ t: TransportSecurity?) -> String {
        switch t {
        case .tls13Pinned?: return "TLS 1.3, pinned certificate · signed messages (\(OriginProtocol.version))"
        case .cleartextLoopbackDevelopment?: return "Cleartext, this Mac only (development)"
        case nil: return "Not listening"
        }
    }
}

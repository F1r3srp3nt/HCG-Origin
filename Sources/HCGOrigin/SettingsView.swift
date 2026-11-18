import SwiftUI
import HCGOriginCore
import HCGOriginProtocol

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Account & Settings", subtitle: "HCG sign-in, gateway identity, connection and background operation.")
                VStack(alignment: .leading, spacing: 16) {
                    AccountPanel(s: s)
                    HStack(alignment: .top, spacing: 16) {
                        IdentityPanel(s: s)
                        ConnectionPanel(s: s)
                    }
                    BackgroundPanel(s: s)
                    AboutPanel(s: s)
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
    }
}

struct AccountPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    @State private var email = ""
    @State private var name = ""
    @State private var devURL = ""

    var body: some View {
        Panel("HCG account and central service") {
            Picker("Central service", selection: Binding(get: { s.settings.centralMode }, set: { model.setMode($0) })) {
                Text("Production HCG").tag(CentralMode.production)
                Text("Local development service (not HCG)").tag(CentralMode.development)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            switch s.settings.centralMode {
            case .production: production
            case .development: development
            }
        }
        .onAppear { devURL = s.settings.developmentServiceURL }
    }

    @ViewBuilder var production: some View {
        if s.production.isComplete {
            FieldRow(label: "HCG Connect issuer", value: s.production.hcgConnectIssuer, mono: true)
            FieldRow(label: "Client ID", value: s.production.hcgConnectClientID, mono: true)
            FieldRow(label: "Central API", value: s.production.centralOriginAPIBase, mono: true)
            if let a = s.account {
                FieldRow(label: "Signed in", value: "\(a.displayName) · \(a.email)")
                Button("Sign Out") { model.signOut() }.hcgButton()
            } else {
                Button("Sign in with HCG Connect…") { model.signInWithHCGConnect() }.hcgPrimaryButton()
                Text("Opens the HCG sign-in page in a secure browser session. Origin never sees your password.")
                    .font(.caption).foregroundStyle(HCG.textDim)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(HCG.warn)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Production enrollment is unavailable").font(.headline)
                    Text("HCG Origin has no issued HCG Connect registration and the central HCG Origin API is not implemented yet. Nothing has been assumed or invented. Missing:")
                        .font(.callout).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
                    ForEach(s.production.problems, id: \.self) { p in
                        Label(p, systemImage: "circle.dashed").font(.callout).foregroundStyle(HCG.textDim)
                    }
                    Text("See docs/CENTRAL-HANDOFF.md for the registration request and the proposed contract.")
                        .font(.caption).foregroundStyle(HCG.textFaint)
                }
            }
            Button("Sign in with HCG Connect…") {}.hcgPrimaryButton().disabled(true)
        }
    }

    @ViewBuilder var development: some View {
        Text("The local development service stands in for HCG Connect and ERP so the enrollment flow can be tested on this Mac. Its accounts are not HCG accounts and its approvals are not HCG verification.")
            .font(.callout).foregroundStyle(HCG.warn).fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField("Development service URL", text: $devURL).textFieldStyle(.roundedBorder).font(HCG.monoSmall)
            Button("Apply") {
                let url = devURL
                model.update { $0.developmentServiceURL = url }
            }.hcgButton().disabled(devURL == s.settings.developmentServiceURL)
        }
        .frame(maxWidth: 620)
        if let a = s.account {
            FieldRow(label: "Development account", value: "\(a.displayName) · \(a.email)")
            FieldRow(label: "Account ID", value: a.accountId, mono: true)
            Button("Sign Out") { model.signOut() }.hcgButton()
        } else {
            HStack {
                TextField("Email for the development account", text: $email).textFieldStyle(.roundedBorder)
                TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                Button("Sign In to Development Service") {
                    model.signInDevelopment(email: email, name: name.isEmpty ? email : name)
                }
                .hcgPrimaryButton()
                .disabled(!email.contains("@") || model.busy)
            }
            .frame(maxWidth: 760)
        }
    }
}

struct IdentityPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    @State private var name = ""

    var body: some View {
        Panel("Gateway identity") {
            HStack {
                TextField("Gateway name", text: $name).textFieldStyle(.roundedBorder)
                Button("Rename") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    model.update { $0.gatewayName = n }
                }.hcgButton().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == s.settings.gatewayName)
            }
            FieldRow(label: "Key fingerprint", value: s.gatewayFingerprint, mono: true, selectable: true)
            FieldRow(label: "Key storage", value: s.keyStorage)
            FieldRow(label: "Proposed gateway ID", value: s.proposedGatewayId + " (local, not issued)", mono: true)
            FieldRow(label: "Issued gateway ID", value: s.registration.map { "\($0.gatewayId) (\($0.environment))" } ?? "Not issued", mono: true, selectable: true)
            FieldRow(label: "Secrets", value: s.secretStorage)
            FieldRow(label: "Data folder", value: OriginPaths.dataDirectory().path, mono: true, selectable: true)
        }
        .onAppear { name = s.settings.gatewayName }
    }
}

struct ConnectionPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    @State private var port = ""

    var body: some View {
        Panel("Connection") {
            FieldRow(label: "Status", value: status)
            HStack {
                Text("Port").foregroundStyle(HCG.textDim).frame(width: 150, alignment: .leading)
                TextField("47700", text: $port).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("Apply") {
                    if let p = UInt16(port), p >= 1024 { model.update { $0.listenPort = p } }
                }.hcgButton().disabled(UInt16(port) == nil || UInt16(port) == s.settings.listenPort)
                Spacer(minLength: 0)
            }
            Button("Restart Listener") { model.restartListener() }.hcgButton()
            Toggle(isOn: Binding(get: { s.settings.allowLocalNetwork }, set: { v in model.update { $0.allowLocalNetwork = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accept devices on the local network")
                    Text("Off: only clients on this Mac can reach Origin. On: devices on your private network can send signed requests; macOS may ask for Local Network permission.")
                        .font(.caption).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            Stepper(value: Binding(get: { s.settings.invitationTTLSeconds / 60 },
                                   set: { v in model.update { $0.invitationTTLSeconds = max(1, min(15, v)) * 60 } }),
                    in: 1...15) {
                Text("Invitation lifetime: \(s.settings.invitationTTLSeconds / 60) min")
            }
            FieldRow(label: "Disconnected after", value: "\(s.settings.disconnectAfterSeconds) s without authenticated contact")
            FieldRow(label: "Requests expire after", value: "\(s.settings.requestTTLSeconds / 60) min without a decision")
        }
        .onAppear { port = String(s.settings.listenPort) }
    }

    var status: String {
        switch s.listener {
        case .listening(let a, _): return "Listening on \(a)"
        case .stopped: return "Stopped"
        case .failed(let e): return "Failed: \(e)"
        }
    }
}

struct BackgroundPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot

    var body: some View {
        Panel("Background operation") {
            Toggle(isOn: Binding(get: { s.settings.keepRunningInBackground },
                                 set: { v in model.update { $0.keepRunningInBackground = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the gateway running when the window is closed")
                    Text(s.settings.keepRunningInBackground
                         ? "On — a menu bar icon shows the gateway status while the window is closed. Quit from that menu to stop it."
                         : "Off — closing the window quits HCG Origin and stops the gateway.")
                        .font(.caption).foregroundStyle(HCG.textDim)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpenAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open HCG Origin when I log in")
                    Text(model.loginItemStatus).font(.caption).foregroundStyle(HCG.textDim)
                }
            }
            .toggleStyle(.switch)
            Text("HCG Origin runs as your normal user account. It installs no helper, daemon or privileged component.")
                .font(.caption).foregroundStyle(HCG.textFaint)
        }
        .onAppear { model.refreshLoginItemStatus() }
    }
}

struct AboutPanel: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot
    var body: some View {
        Panel("About this build") {
            FieldRow(label: "HCG Origin", value: model.build.summary, mono: true, selectable: true)
            FieldRow(label: "Built", value: model.build.builtAt)
            FieldRow(label: "Protocol", value: "\(OriginProtocol.version) · central contract: proposed, not issued")
            FieldRow(label: "Signing", value: "Ad hoc (development). Not notarized.")
        }
    }
}

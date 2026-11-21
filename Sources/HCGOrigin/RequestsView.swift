import SwiftUI
import AppKit
import CoreImage
import HCGOriginCore
import HCGOriginProtocol

struct RequestsView: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot

    var selected: EnrollmentRecord? {
        s.requests.first { $0.id == model.selectedRequestId } ?? s.requests.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Connection Requests",
                          subtitle: "Enrollment requests from Connector clients and their verification state. An invitation is not approval.",
                          trailing: AnyView(PairingButton(s: s)))
            Picker("Source", selection: $model.requestSource) {
                Text("HCG Connector (hcg-origin/2)").tag(0)
                Text("HCG Server Device Link (\(s.server.pendingPairings.count) pending)").tag(1)
            }
            .pickerStyle(.segmented).frame(maxWidth: 560).padding(.horizontal, 28).padding(.bottom, 12)
            if model.requestSource == 1 {
                ScrollView { ServerRequestsSection(s: s).padding(.horizontal, 28).padding(.bottom, 24) }
            } else if s.requests.isEmpty {
                EmptyState(symbol: "person.badge.key",
                           title: "No requests yet",
                           message: emptyMessage)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(s.requests) { r in
                                RequestRow(r: r, selected: r.id == selected?.id, now: s.now)
                                    .onTapGesture { model.selectedRequestId = r.id }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .frame(width: 330)
                    ScrollView {
                        if let r = selected { RequestDetail(r: r, s: s).padding(.bottom, 20) }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    var emptyMessage: String {
        if case .unavailable(let reason) = s.pairing { return reason }
        return "Start pairing to create a short-lived invitation, then enter it on the device in the Connector (or the development test client)."
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(HCG.cyan.opacity(0.8))
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(HCG.textDim).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct RequestRow: View {
    let r: EnrollmentRecord
    let selected: Bool
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.device.name).font(.headline).lineLimit(1)
                Spacer()
                Badge(text: r.state.label, tone: r.state.tone)
            }
            HStack(spacing: 6) {
                Text(r.device.platform).lineLimit(1)
                if r.device.clientKind == "connector-test-client" { Badge(text: "TEST CLIENT", tone: .dev) }
                if r.environment == "development" { Badge(text: "DEV", tone: .dev) }
            }
            .font(.caption).foregroundStyle(HCG.textDim)
            HStack {
                Text("Check \(r.checkCode)").font(HCG.monoSmall).foregroundStyle(HCG.cyan)
                Spacer()
                Text(Fmt.ago(r.receivedAt, now: now)).font(.caption).foregroundStyle(HCG.textFaint)
            }
            if let e = r.lastCentralError, r.isOpen {
                Text(e).font(.caption2).foregroundStyle(HCG.warn).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? HCG.raised : HCG.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? HCG.cyan.opacity(0.6) : HCG.edge, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct RequestDetail: View {
    @EnvironmentObject var model: AppModel
    let r: EnrollmentRecord
    let s: GatewaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Panel {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.device.name).font(.title2.weight(.semibold))
                        Text("\(r.device.platform) · \(r.device.clientKind == "connector-test-client" ? "Connector development test client" : "HCG Connector") \(r.device.softwareVersion)")
                            .font(.callout).foregroundStyle(HCG.textDim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("CHECK CODE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(HCG.textFaint)
                        Text(r.checkCode).font(.system(size: 26, weight: .medium, design: .monospaced)).foregroundStyle(HCG.cyan)
                        Text("Must match the device").font(.caption2).foregroundStyle(HCG.textFaint)
                    }
                }
                HStack(spacing: 8) {
                    Badge(text: r.state.label, tone: r.state.tone)
                    Badge(text: r.environment == "development" ? "DEVELOPMENT RESULT" : "PRODUCTION", tone: r.environment == "development" ? .dev : .info)
                    if let d = r.decidedAt { Text("Decided \(Fmt.dateTime.string(from: d))").font(.caption).foregroundStyle(HCG.textDim) }
                }
                if let reason = r.decisionReason {
                    Text(reason).font(.callout).foregroundStyle(r.state == .approved ? HCG.textDim : HCG.err)
                }
            }

            Panel("Verification") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(r.steps) { step in StepRow(step: step) }
                }
            }

            Panel("Capabilities") {
                ForEach(r.requestedCapabilities.sorted(), id: \.self) { cap in
                    HStack(spacing: 8) {
                        Image(systemName: icon(cap)).foregroundStyle(tone(cap).color).frame(width: 16)
                        Text(Fmt.capability(cap))
                        Text(cap).font(HCG.monoSmall).foregroundStyle(HCG.textFaint)
                        Spacer()
                        Text(capState(cap)).font(.caption).foregroundStyle(tone(cap).color)
                    }
                }
                Text("Enrollment never grants command execution. Execution requires separate Agent Runtime authorisation.")
                    .font(.caption).foregroundStyle(HCG.textFaint)
            }

            Panel("Identifiers") {
                FieldRow(label: "Local request", value: r.id, mono: true, selectable: true)
                FieldRow(label: "Central enrollment", value: r.centralEnrollmentId ?? "Not issued yet", mono: true, selectable: true)
                FieldRow(label: "Device ID", value: r.issuedDeviceId ?? "Not issued (proposed \(r.device.proposedDeviceId))", mono: true, selectable: true)
                FieldRow(label: "Device key", value: r.deviceFingerprint, mono: true, selectable: true)
                FieldRow(label: "Invitation", value: r.invitationId, mono: true)
                FieldRow(label: "Received from", value: "\(r.observedFrom) at \(Fmt.dateTime.string(from: r.receivedAt))")
                if r.isOpen { FieldRow(label: "Expires", value: Fmt.dateTime.string(from: r.expiresAt)) }
            }

            if !r.isOpen {
                Button("Remove from list") { model.dismissRequest(r.id) }.hcgButton()
            }
        }
    }

    func capState(_ cap: String) -> String {
        if r.refusedCapabilities.contains(where: { $0.capability == cap }) { return Capability.isExecutionLike(cap) ? "Refused — Agent Runtime only" : "Refused — unknown" }
        if let g = r.grant { return g.allows(cap) ? "Granted" : "Not granted" }
        if r.state == .rejected || r.state == .expired || r.state == .failed { return "Not granted" }
        return "Awaiting decision"
    }
    func tone(_ cap: String) -> Tone {
        switch capState(cap) {
        case "Granted": return .ok
        case "Awaiting decision": return .warn
        default: return .err
        }
    }
    func icon(_ cap: String) -> String {
        switch capState(cap) {
        case "Granted": return "checkmark.circle.fill"
        case "Awaiting decision": return "clock"
        default: return "xmark.circle"
        }
    }
}

struct StepRow: View {
    let step: VerificationStep
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tone.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.callout)
                if let d = step.detail { Text(d).font(.caption).foregroundStyle(HCG.textDim).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if let at = step.at { Text(Fmt.time.string(from: at)).font(.caption2).foregroundStyle(HCG.textFaint) }
        }
    }
    var symbol: String {
        switch step.result {
        case .passed: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        case .pending: return "hourglass"
        case .notApplicable: return "minus.circle"
        }
    }
    var tone: Tone {
        switch step.result { case .passed: return .ok; case .failed: return .err; case .pending: return .warn; case .notApplicable: return .neutral }
    }
}

// MARK: Pairing invitation

struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pairing invitation").font(.title2.weight(.semibold))
                    Text("Single use. Lets one device submit an enrollment request — it does not approve the device.")
                        .font(.callout).foregroundStyle(HCG.textDim)
                }
                Spacer()
            }
            if let s = model.snapshot, s.isDevelopment { DevelopmentBanner().clipShape(RoundedRectangle(cornerRadius: 8)) }
            if let inv = model.snapshot?.activeInvitation {
                HStack(alignment: .top, spacing: 20) {
                    QRCodeView(text: inv.code)
                        .frame(width: 210, height: 210)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                    VStack(alignment: .leading, spacing: 10) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(inv.expiresAt.timeIntervalSince(ctx.date)))
                            HStack(spacing: 8) {
                                StatusDot(tone: left > 30 ? .ok : .warn, pulsing: true)
                                Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired")
                                    .font(.system(.title3, design: .monospaced))
                            }
                        }
                        FieldRow(label: "Gateway address", value: inv.address, mono: true)
                        FieldRow(label: "Encryption", value: inv.tlsFingerprint.map { "TLS 1.3 · pinned key \(KeyFingerprint.short($0))" } ?? "None (development, this Mac only)")
                        FieldRow(label: "Environment", value: inv.environment == "development" ? "Development (local service)" : "Production")
                        Text("INVITATION CODE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(HCG.textFaint)
                        Text(inv.code)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(HCG.textDim)
                            .textSelection(.enabled)
                            .lineLimit(5)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(HCG.obsidian))
                        HStack {
                            Button(copied ? "Copied" : "Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(inv.code, forType: .string)
                                copied = true
                            }.hcgButton()
                            Spacer()
                        }
                    }
                }
                Panel("Next") {
                    Text("1. Enter or scan the code on the device in HCG Connector. For development, use the test client:")
                        .font(.callout)
                    Text("pbpaste | hcg-connector-testclient enroll --code - --wait")
                        .font(HCG.monoSmall).foregroundStyle(HCG.cyan).textSelection(.enabled)
                    Text("2. Compare the check code shown on the device with the one in Connection Requests.\n3. The decision is made centrally (ERP); Origin then allows only what was granted.")
                        .font(.callout).foregroundStyle(HCG.textDim)
                }
            } else {
                Panel {
                    Text(lastInvitationOutcome).font(.callout).foregroundStyle(HCG.textDim)
                }
            }
            HStack {
                Spacer()
                if model.snapshot?.activeInvitation != nil {
                    Button("Cancel Invitation") { model.cancelPairing() }.hcgButton()
                }
                Button("Done") { model.showPairing = false }.hcgPrimaryButton().keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(HCG.surface)
        .preferredColorScheme(.dark)
    }

    var lastInvitationOutcome: String {
        if let r = model.snapshot?.requests.first, Date().timeIntervalSince(r.receivedAt) < 600 {
            return "The invitation was used by \(r.device.name). Check code \(r.checkCode). Follow its progress in Connection Requests."
        }
        return "No active invitation. It was used, cancelled or expired. Start pairing again to create a new one."
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = QRCode.image(for: text) {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .accessibilityLabel("QR code containing the pairing invitation")
        } else {
            Text("QR code unavailable").foregroundStyle(.black)
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

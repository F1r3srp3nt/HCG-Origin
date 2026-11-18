import SwiftUI
import HCGOriginCore
import HCGOriginProtocol

struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    let s: GatewaySnapshot

    var selected: DeviceView? { s.devices.first { $0.id == model.selectedDeviceId } ?? s.devices.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Devices",
                          subtitle: "Devices admitted through central verification. Only real enrolled devices appear here.")
            if s.devices.isEmpty {
                EmptyState(symbol: "laptopcomputer.and.iphone", title: "No enrolled devices",
                           message: "A device appears here only after central HCG (or, in development, the local service) approves its enrollment request.")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(s.devices) { d in
                                DeviceRow(d: d, selected: d.id == selected?.id, now: s.now)
                                    .onTapGesture { model.selectedDeviceId = d.id }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .frame(width: 340)
                    ScrollView {
                        if let d = selected { DeviceDetail(d: d, s: s).padding(.bottom, 20) }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }
}

struct DeviceRow: View {
    let d: DeviceView
    let selected: Bool
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(tone: d.connection.tone, pulsing: d.connection == .connected)
                Text(d.record.name).font(.headline).lineLimit(1)
                Spacer()
                Badge(text: d.connection.label, tone: d.connection.tone)
            }
            HStack(spacing: 6) {
                Text(d.record.platform).lineLimit(1)
                if d.record.clientKind == "connector-test-client" { Badge(text: "TEST CLIENT", tone: .dev) }
                if d.record.environment == "development" { Badge(text: "DEV", tone: .dev) }
            }
            .font(.caption).foregroundStyle(HCG.textDim)
            Text("Last contact \(Fmt.ago(d.record.lastContactAt, now: now))").font(.caption).foregroundStyle(HCG.textFaint)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? HCG.raised : HCG.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? HCG.cyan.opacity(0.6) : HCG.edge, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct DeviceDetail: View {
    @EnvironmentObject var model: AppModel
    let d: DeviceView
    let s: GatewaySnapshot

    var body: some View {
        let r = d.record
        VStack(alignment: .leading, spacing: 14) {
            Panel {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.name).font(.title2.weight(.semibold))
                        Text("\(r.platform)\(r.model.map { " · \($0)" } ?? "")").font(.callout).foregroundStyle(HCG.textDim)
                    }
                    Spacer()
                    Badge(text: d.connection.label, tone: d.connection.tone)
                }
                if r.environment == "development" {
                    Text("Admitted by the local development service. This is not HCG verification.")
                        .font(.caption).foregroundStyle(HCG.warn)
                }
                if let reason = r.statusReason, r.status != .active {
                    Text(reason).font(.callout).foregroundStyle(HCG.err)
                }
            }
            Panel("Connection") {
                FieldRow(label: "State", value: d.connection.label)
                FieldRow(label: "Last contact", value: r.lastContactAt.map { "\(Fmt.dateTime.string(from: $0)) (\(Fmt.ago($0, now: s.now)))" } ?? "Never")
                FieldRow(label: "From", value: r.lastContactFrom ?? "—")
                FieldRow(label: "Connected since", value: r.connectedSince.map { Fmt.dateTime.string(from: $0) } ?? "—")
                if let rep = r.lastReport {
                    FieldRow(label: "Reported OS", value: rep.osVersion ?? "—")
                    FieldRow(label: "Uptime", value: rep.uptimeSeconds.map { "\($0 / 3600) h \(($0 % 3600) / 60) min" } ?? "—")
                    if let b = rep.batteryPercent { FieldRow(label: "Battery", value: "\(b)%") }
                }
            }
            Panel("Granted capabilities") {
                if r.grant.capabilities.isEmpty {
                    Text("Nothing granted.").foregroundStyle(HCG.textDim)
                }
                ForEach(r.grant.capabilities, id: \.self) { cap in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(HCG.ok)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Fmt.capability(cap))
                            Text(Capability.info(cap)?.detail ?? cap).font(.caption).foregroundStyle(HCG.textDim)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle").foregroundStyle(HCG.err)
                    Text("Command execution — not granted. Requires separate Agent Runtime authorisation.").font(.callout).foregroundStyle(HCG.textDim)
                }
                FieldRow(label: "Decided by", value: r.grant.decidedBy == "hcg-erp" ? "HCG ERP" : "Local development service (not HCG)")
                FieldRow(label: "Granted", value: Fmt.dateTime.string(from: r.grant.grantedAt))
            }
            Panel("Identity") {
                FieldRow(label: "Device ID (issued)", value: r.id, mono: true, selectable: true)
                FieldRow(label: "Proposed by device", value: r.proposedDeviceId, mono: true)
                FieldRow(label: "Key fingerprint", value: r.fingerprint, mono: true, selectable: true)
                FieldRow(label: "Client", value: r.clientKind == "connector-test-client" ? "Connector development test client \(r.softwareVersion)" : "HCG Connector \(r.softwareVersion)")
                FieldRow(label: "Enrolled", value: Fmt.dateTime.string(from: r.enrolledAt))
            }
            Panel("Access on this gateway") {
                switch r.status {
                case .active:
                    Text("Revoking admission happens centrally in ERP and is reflected here on the next sync. Blocking only stops this gateway from accepting the device.")
                        .font(.caption).foregroundStyle(HCG.textDim)
                    Button("Block on This Gateway") { model.block(r.id) }.hcgButton()
                case .blockedLocally:
                    Button("Unblock") { model.unblock(r.id) }.hcgButton()
                case .revoked:
                    Text("Revoked centrally. Origin rejects every request from this device key.").font(.caption).foregroundStyle(HCG.textDim)
                    Button("Remove Record") { model.removeRecord(r.id) }.hcgButton()
                }
            }
        }
    }
}

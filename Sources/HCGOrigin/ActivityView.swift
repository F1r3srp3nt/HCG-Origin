import SwiftUI
import HCGOriginCore

struct ActivityView: View {
    let s: GatewaySnapshot
    @State private var filter: ActivityKind? = nil
    @State private var onlyProblems = false

    var entries: [ActivityEntry] {
        s.activity.filter { e in
            (filter == nil || e.kind == filter) && (!onlyProblems || e.severity == .warning || e.severity == .error)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Activity", subtitle: "Enrollment decisions, connection events and errors. Stored on this Mac without secrets.")
            HStack(spacing: 6) {
                FilterChip(title: "All", on: filter == nil) { filter = nil }
                ForEach([ActivityKind.pairing, .enrollment, .decision, .connection, .revocation, .security, .central, .error], id: \.self) { k in
                    FilterChip(title: k.rawValue.capitalized, on: filter == k) { filter = k }
                }
                Spacer()
                Toggle("Warnings and errors only", isOn: $onlyProblems).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 28).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if entries.isEmpty {
                        Text("Nothing to show.").foregroundStyle(HCG.textDim).padding(30)
                    }
                    ForEach(entries) { e in
                        ActivityRow(entry: e, now: s.now, compact: false)
                        Divider().overlay(HCG.edge)
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(HCG.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HCG.edge))
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(on ? HCG.cyan : HCG.textDim)
                .background(Capsule().fill(on ? HCG.cyanSoft : HCG.surface))
                .overlay(Capsule().stroke(on ? HCG.cyan.opacity(0.5) : HCG.edge))
        }
        .buttonStyle(.plain)
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    let now: Date
    let compact: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(entry.severity.tone.color).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title).font(.callout.weight(.medium))
                    if entry.environment == "development" && !compact { Badge(text: "DEV", tone: .dev) }
                }
                Text(entry.detail).font(.caption).foregroundStyle(HCG.textDim)
                    .lineLimit(compact ? 1 : nil).fixedSize(horizontal: false, vertical: !compact)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(compact ? Fmt.ago(entry.at, now: now) : Fmt.dateTime.string(from: entry.at)).font(.caption2).foregroundStyle(HCG.textFaint)
                if !compact { Text(entry.kind.rawValue).font(.caption2).foregroundStyle(HCG.textFaint) }
            }
        }
        .padding(.vertical, 9)
    }

    var symbol: String {
        switch entry.kind {
        case .pairing: return "qrcode"
        case .enrollment: return "person.badge.key"
        case .decision: return entry.severity == .success ? "checkmark.seal" : "xmark.seal"
        case .connection: return "dot.radiowaves.left.and.right"
        case .revocation: return "hand.raised"
        case .security: return "lock.trianglebadge.exclamationmark"
        case .central: return "building.columns"
        case .account: return "person.crop.circle"
        case .gateway: return "server.rack"
        case .error: return "exclamationmark.octagon"
        }
    }
}

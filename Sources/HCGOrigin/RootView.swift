import SwiftUI
import HCGOriginCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 236)
            Rectangle().fill(HCG.edge).frame(width: 1)
            VStack(spacing: 0) {
                if model.snapshot?.isDevelopment == true { DevelopmentBanner() }
                if let notice = model.notice { NoticeStrip(text: notice) { model.notice = nil } }
                if let err = model.snapshot?.startupError { NoticeStrip(text: "Gateway unavailable: \(err)", dismiss: nil) }
                Group {
                    if let s = model.snapshot {
                        switch model.section {
                        case .overview: OverviewView(s: s)
                        case .requests: RequestsView(s: s)
                        case .devices: DevicesView(s: s)
                        case .activity: ActivityView(s: s)
                        case .settings: SettingsView(s: s)
                        }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Starting the gateway…").foregroundStyle(HCG.textDim)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(HCG.obsidian)
        }
        .background(HCG.obsidian)
        .foregroundStyle(HCG.text)
        .tint(HCG.cyan)
        .sheet(isPresented: $model.showPairing) {
            PairingSheet().environmentObject(model)
        }
    }
}

struct NoticeStrip: View {
    let text: String
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(HCG.err)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.plain).foregroundStyle(HCG.textDim) }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(HCG.err.opacity(0.12))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(HCG.err.opacity(0.4)), alignment: .bottom)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                BrandMark(height: 40)
                Text("ORIGIN")
                    .font(.system(size: 13, weight: .semibold)).tracking(5)
                    .foregroundStyle(HCG.silver)
                Text("Device gateway")
                    .font(.caption).foregroundStyle(HCG.textFaint)
            }
            .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarRow(section: section, selected: model.section == section, badge: badge(for: section))
                        .contentShape(Rectangle())
                        .onTapGesture { model.section = section }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            if let s = model.snapshot { SidebarStatus(s: s).padding(14) }
        }
        .background(
            LinearGradient(colors: [HCG.surface, HCG.obsidian], startPoint: .top, endPoint: .bottom)
        )
    }

    func badge(for section: AppSection) -> Int? {
        guard let s = model.snapshot else { return nil }
        switch section {
        case .requests: return s.openRequestCount > 0 ? s.openRequestCount : nil
        case .devices: return s.connectedCount > 0 ? s.connectedCount : nil
        default: return nil
        }
    }
}

struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let badge: Int?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? HCG.cyan : HCG.textDim)
            Text(section.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? HCG.text : HCG.textDim)
            Spacer()
            if let badge {
                Text("\(badge)").font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(HCG.cyanSoft))
                    .foregroundStyle(HCG.cyan)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? HCG.cyanSoft : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(HCG.cyan).frame(width: 3, height: 18).offset(x: -1)
            }
        }
    }
}

struct SidebarStatus: View {
    let s: GatewaySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(tone: listenerTone, pulsing: listenerTone == .ok)
                Text(listenerText).font(.caption).foregroundStyle(HCG.textDim).lineLimit(2)
            }
            HStack(spacing: 8) {
                StatusDot(tone: centralTone)
                Text(centralText).font(.caption).foregroundStyle(HCG.textDim).lineLimit(2)
            }
            Badge(text: s.isDevelopment ? "DEVELOPMENT" : "PRODUCTION", tone: s.isDevelopment ? .dev : .info)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(HCG.obsidian.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HCG.edge))
    }

    var listenerTone: Tone {
        switch s.listener { case .listening: return .ok; case .stopped: return .neutral; case .failed: return .err }
    }
    var listenerText: String {
        switch s.listener {
        case .listening(let a, let lan): return "Gateway \(lan ? "on local network" : "on this Mac") · \(a)"
        case .stopped: return "Gateway stopped"
        case .failed: return "Gateway listener failed"
        }
    }
    var centralTone: Tone { CentralText.tone(s.central.reachability) }
    var centralText: String { CentralText.short(s) }
}

enum CentralText {
    static func tone(_ r: CentralReachability) -> Tone {
        switch r {
        case .reachable: return .ok
        case .unknown: return .neutral
        case .notConfigured: return .warn
        case .unreachable, .mismatch: return .err
        }
    }

    static func short(_ s: GatewaySnapshot) -> String {
        switch s.central.reachability {
        case .reachable: return s.isDevelopment ? "Development service reachable" : "HCG central reachable"
        case .unknown: return "Central service: checking…"
        case .notConfigured: return "Production HCG not configured"
        case .unreachable: return s.isDevelopment ? "Development service unreachable" : "HCG central unreachable"
        case .mismatch: return "Central environment mismatch"
        }
    }

    static func detail(_ s: GatewaySnapshot) -> String {
        switch s.central.reachability {
        case .reachable(let service, let at): return "\(service) — answered \(Fmt.ago(at, now: s.now))."
        case .unknown: return "Waiting for the first check."
        case .notConfigured(let missing): return "Missing: " + missing.joined(separator: "; ") + "."
        case .unreachable(let d, let since): return "\(d) Since \(Fmt.time.string(from: since)). Requests stay pending and are retried."
        case .mismatch(let m): return m
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(HCG.textDim)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
    }
}

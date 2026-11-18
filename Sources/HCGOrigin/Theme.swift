import SwiftUI
import AppKit

/// HCG visual language (shared with HCG Server / Terminal / Nexus): obsidian
/// surfaces, brushed silver text, cyan edge light.
enum HCG {
    static let obsidian = Color(red: 0.020, green: 0.031, blue: 0.043)      // #05080B
    static let surface = Color(red: 0.047, green: 0.071, blue: 0.090)       // #0C1217
    static let raised = Color(red: 0.067, green: 0.102, blue: 0.129)        // #111A21
    static let high = Color(red: 0.094, green: 0.110, blue: 0.133)          // #181C22
    static let edge = Color.white.opacity(0.09)
    static let edgeStrong = Color.white.opacity(0.16)
    static let cyan = Color(red: 0.184, green: 0.827, blue: 0.902)          // #2FD3E6
    static let cyanSoft = Color(red: 0.184, green: 0.827, blue: 0.902).opacity(0.14)
    static let text = Color.white.opacity(0.93)
    static let textDim = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.45)
    static let ok = Color(red: 0.361, green: 0.800, blue: 0.561)            // #5CCC8F
    static let warn = Color(red: 0.922, green: 0.722, blue: 0.302)          // #EBB84D
    static let err = Color(red: 0.949, green: 0.451, blue: 0.451)           // #F27373
    static let silver = Color(red: 0.773, green: 0.824, blue: 0.859)        // #C5D2DB

    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
}

struct PanelHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(HCG.textFaint)
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct Panel<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { PanelHeader(title: title) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [HCG.raised, HCG.surface], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HCG.edge, lineWidth: 1))
    }
}

enum Tone { case ok, warn, err, info, neutral, dev
    var color: Color {
        switch self {
        case .ok: return HCG.ok
        case .warn: return HCG.warn
        case .err: return HCG.err
        case .info: return HCG.cyan
        case .neutral: return HCG.textDim
        case .dev: return HCG.warn
        }
    }
}

struct Badge: View {
    let text: String
    var tone: Tone = .neutral
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tone.color)
            .background(Capsule().fill(tone.color.opacity(0.12)))
            .overlay(Capsule().stroke(tone.color.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }
}

struct StatusDot: View {
    var tone: Tone
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .shadow(color: tone.color.opacity(0.8), radius: on ? 5 : 2)
            .onAppear {
                guard pulsing && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tone: Tone = .neutral
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(1.0)
                .foregroundStyle(HCG.textFaint)
            Text(value)
                .font(.system(size: 30, weight: .light, design: .rounded))
                .foregroundStyle(tone == .neutral ? HCG.text : tone.color)
                .monospacedDigit()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(HCG.textDim).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HCG.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HCG.edge, lineWidth: 1))
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    var mono = false
    var selectable = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(HCG.textDim).frame(width: 150, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(mono ? HCG.monoSmall : .callout)
            .foregroundStyle(HCG.text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// Persistent banner whenever Origin is using the local development service.
struct DevelopmentBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("LOCAL DEVELOPMENT SERVICE — NOT HCG")
                    .font(.system(size: 11.5, weight: .bold)).tracking(0.8)
                Text("Account checks and approvals come from the development service on this Mac. They are not HCG verification.")
                    .font(.caption)
            }
            Spacer()
        }
        .foregroundStyle(Color(red: 1.0, green: 0.886, blue: 0.639))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            ZStack {
                Color(red: 0.227, green: 0.165, blue: 0.020)
                StripePattern().opacity(0.25)
            }
        )
        .overlay(Rectangle().frame(height: 1).foregroundStyle(HCG.warn.opacity(0.7)), alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

struct StripePattern: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + 8, y: 0))
                p.addLine(to: CGPoint(x: x + 8, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(.black))
                x += 22
            }
        }
    }
}

enum Brand {
    /// The HCG wordmark copied into Contents/Resources by the build script.
    static let wordmark: NSImage? = image(named: "hcg-wordmark")

    static func image(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
        // `swift run` during development: look next to the package.
        if let dir = ProcessInfo.processInfo.environment["HCG_ORIGIN_RESOURCES"] {
            return NSImage(contentsOfFile: dir + "/\(name).png")
        }
        return nil
    }
}

struct BrandMark: View {
    var height: CGFloat = 34
    var body: some View {
        if let img = Brand.wordmark {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: height)
                .accessibilityLabel("HCG")
        } else {
            Text("HCG").font(.system(size: height * 0.7, weight: .heavy)).foregroundStyle(HCG.silver)
        }
    }
}

extension View {
    func hcgPrimaryButton() -> some View {
        self.buttonStyle(HCGButtonStyle(prominent: true))
    }
    func hcgButton() -> some View {
        self.buttonStyle(HCGButtonStyle(prominent: false))
    }
}

struct HCGButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.black.opacity(isEnabled ? 0.9 : 0.5) : (isEnabled ? HCG.text : HCG.textFaint))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? (isEnabled ? HCG.cyan : HCG.cyan.opacity(0.3)) : HCG.high)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(prominent ? Color.clear : HCG.edgeStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

#if HCG_UI_AUTOMATION
import SwiftUI
import AppKit
import HCGOriginCore
import HCGOriginProtocol

/// UI-AUTOMATION BUILDS ONLY (compiled with -DHCG_UI_AUTOMATION; release builds do not
/// contain this file's code). Lets scripts/verify-on-mac.sh drive the real app the way a
/// person would — press Start Pairing, switch sections — and capture the window.
///
/// Commands are JSON files in $HCG_ORIGIN_AUTOMATION_DIR/commands; results are written to
/// $HCG_ORIGIN_AUTOMATION_DIR/results. Nothing here bypasses the engine's rules.
@MainActor
final class UIAutomation {
    static let shared = UIAutomation()
    private weak var model: AppModel?
    private var timer: Timer?
    private var dir: URL?

    struct Command: Decodable { var id: String; var action: String; var arg: String? }

    func attach(model: AppModel) {
        guard self.model == nil, let path = ProcessInfo.processInfo.environment["HCG_ORIGIN_AUTOMATION_DIR"] else { return }
        self.model = model
        let d = URL(fileURLWithPath: path)
        dir = d
        for sub in ["commands", "results", "screenshots"] {
            try? FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        write("ready.json", ["pid": "\(ProcessInfo.processInfo.processIdentifier)", "build": model.build.summary])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in UIAutomation.shared.poll() }
        }
    }

    private var busy = false

    private func poll() {
        guard !busy, let dir else { return }
        let cmdDir = dir.appendingPathComponent("commands")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: cmdDir.path).filter({ $0.hasSuffix(".json") }).sorted(),
              let first = files.first else { return }
        let url = cmdDir.appendingPathComponent(first)
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let cmd = try? JSONDecoder().decode(Command.self, from: data) else { return }
        busy = true
        Task { @MainActor in
            let result = await self.run(cmd)
            self.write("results/\(cmd.id).json", result)
            self.busy = false
        }
    }

    private func run(_ c: Command) async -> [String: String] {
        guard let model else { return ["ok": "false", "error": "no model"] }
        do {
            switch c.action {
            case "select":
                guard let s = AppSection(rawValue: c.arg ?? "") else { throw Failure("unknown section") }
                model.showPairing = false
                model.section = s
            case "setMode":
                guard let m = CentralMode(rawValue: c.arg ?? "") else { throw Failure("unknown mode") }
                await model.engine.updateSettings { $0.centralMode = m }
            case "setDevURL":
                let url = c.arg ?? ""
                await model.engine.updateSettings { $0.developmentServiceURL = url }
            case "setBackground":
                let on = c.arg == "true"
                await model.engine.updateSettings { $0.keepRunningInBackground = on }
            case "setInvitationTTL":
                let seconds = Int(c.arg ?? "") ?? 300
                await model.engine.updateSettings { $0.invitationTTLSeconds = seconds }
            case "devSignIn":
                try await model.engine.signInDevelopment(email: c.arg ?? "owner@dev.local", displayName: "Development Owner")
            case "sync":
                await model.engine.syncNow()
            case "startPairing":
                // Same path as the Start Pairing button.
                model.section = .requests
                let inv = try await model.engine.startPairing()
                model.showPairing = true
                write("invitation.txt", raw: inv.code)
            case "closeSheet":
                model.showPairing = false
            case "selectFirstRequest":
                model.selectedRequestId = model.snapshot?.requests.first?.id
            case "selectFirstDevice":
                model.selectedDeviceId = model.snapshot?.devices.first?.id
            case "blockFirstDevice":
                if let id = model.snapshot?.devices.first?.id { await model.engine.blockDeviceLocally(id: id) }
            case "screenshot":
                try await Task.sleep(nanoseconds: 700_000_000)
                let name = c.arg ?? "screen"
                try snapshotWindow(to: dir!.appendingPathComponent("screenshots/\(name)-window.png"))
            case "state":
                break
            case "quit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            default:
                throw Failure("unknown action \(c.action)")
            }
            var out = state()
            out["ok"] = "true"
            return out
        } catch {
            var out = state()
            out["ok"] = "false"
            out["error"] = "\(error)"
            return out
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    /// Compact state for assertions (never contains the invitation code or tokens).
    private func state() -> [String: String] {
        guard let s = model?.snapshot else { return [:] }
        var o: [String: String] = [:]
        o["pairing"] = { if case .unavailable(let r) = s.pairing { return "unavailable: \(r)" }; return "available" }()
        o["central"] = "\(s.central.reachability)"
        o["mode"] = s.settings.centralMode.rawValue
        o["account"] = s.account?.email ?? ""
        o["gatewayId"] = s.registration?.gatewayId ?? ""
        o["requests"] = s.requests.map { "\($0.id)=\($0.state.rawValue)/\($0.checkCode)" }.joined(separator: ",")
        o["devices"] = s.devices.map { "\($0.id)=\($0.record.status.rawValue)/\($0.connection.rawValue)" }.joined(separator: ",")
        o["activity"] = s.activity.prefix(40).map(\.title).joined(separator: "|")
        o["invitationActive"] = s.activeInvitation == nil ? "false" : "true"
        o["windowNumber"] = "\(NSApp.windows.first(where: { $0.isVisible && $0.title == "HCG Origin" })?.windowNumber ?? -1)"
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "HCG Origin" }), let screen = w.screen ?? NSScreen.main {
            // screencapture -R takes top-left-origin screen coordinates.
            let f = w.frame
            let top = screen.frame.maxY - f.maxY
            o["windowRect"] = "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
        }
        return o
    }

    private func snapshotWindow(to url: URL) throws {
        let windows = NSApp.windows.filter { $0.isVisible }
        guard let window = windows.first(where: { $0.attachedSheet != nil }) ?? windows.first(where: { $0.title == "HCG Origin" }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView else { throw Failure("no window") }
        var images: [(NSImage, NSRect)] = []
        func capture(_ w: NSWindow) {
            guard let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(rep)
            images.append((img, w.frame))
        }
        capture(window)
        if let sheet = window.attachedSheet { capture(sheet) }
        let base = window.frame
        let scale = window.backingScaleFactor
        let size = NSSize(width: base.width * scale, height: base.height * scale)
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (img, frame) in images {
            let r = NSRect(x: (frame.minX - base.minX) * scale, y: (frame.minY - base.minY) * scale,
                           width: frame.width * scale, height: frame.height * scale)
            img.draw(in: r)
        }
        out.unlockFocus()
        _ = view
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw Failure("encode failed") }
        try png.write(to: url)
    }

    private func write(_ name: String, _ dict: [String: String]) {
        guard let dir, let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]) else { return }
        let target = dir.appendingPathComponent(name)
        try? data.write(to: target.appendingPathExtension("tmp"))
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: target.appendingPathExtension("tmp"), to: target)
    }

    private func write(_ name: String, raw: String) {
        guard let dir else { return }
        let url = dir.appendingPathComponent(name)
        try? raw.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif

import SwiftUI
import AppKit
import HCGOriginCore

@main
struct HCGOriginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("HCG Origin", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { delegate.model = model }
                #if HCG_UI_AUTOMATION
                .onAppear { UIAutomation.shared.attach(model: model) }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Gateway") {
                Button("Start Pairing…") { model.section = .requests; model.startPairing() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.snapshot?.pairing != .available)
                Button("Synchronise with Central Service") { model.syncNow() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        // Visible status whenever Origin keeps running in the background.
        MenuBarExtra(isInserted: Binding(
            get: { model.snapshot?.settings.keepRunningInBackground ?? false },
            set: { _ in })) {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: menuSymbol)
        }
    }

    private var menuSymbol: String {
        guard let s = model.snapshot else { return "circle.dashed" }
        if case .listening = s.listener { return s.connectedCount > 0 ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right" }
        return "exclamationmark.triangle"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Background operation is an explicit setting; by default closing the window quits
        // and stops the gateway.
        !(model?.snapshot?.settings.keepRunningInBackground ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let engine = model?.engine else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await engine.shutdown(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let s = model.snapshot {
            Text("HCG Origin — gateway running in the background")
            Text(listenerLine(s))
            Text("\(s.connectedCount) connected · \(s.enrolledCount) enrolled · \(s.openRequestCount) pending")
            if s.isDevelopment { Text("Using the LOCAL DEVELOPMENT SERVICE (not HCG)") }
            Divider()
        }
        Button("Open HCG Origin") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Stop Running in Background") { model.update { $0.keepRunningInBackground = false } }
        Divider()
        Button("Quit HCG Origin") { NSApp.terminate(nil) }
    }

    func listenerLine(_ s: GatewaySnapshot) -> String {
        switch s.listener {
        case .listening(let a, _): return "Listening on \(a)"
        case .stopped: return "Listener stopped"
        case .failed(let e): return "Listener failed: \(e)"
        }
    }
}

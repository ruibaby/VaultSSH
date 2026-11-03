import SwiftUI
import AppKit

@main
struct VaultSSHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("VaultSSH", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1060, height: 720)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var approvalPanel: ApprovalPanelController?
    private var securityMonitor: SecurityMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        approvalPanel = ApprovalPanelController()
        securityMonitor = SecurityMonitor { AppModel.shared.automaticLock() }
        securityMonitor?.start()
        Task { @MainActor in
            await AppModel.shared.bootstrap()
        }
        // If the restored frame was saved on a display that is no longer
        // connected, bring the window back onto a visible screen.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.centerWindowIfOffscreen()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        securityMonitor?.stop()
        AppModel.shared.shutdown()
    }

    private func centerWindowIfOffscreen() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && !($0 is NSPanel) && $0.frame.width >= 600 && $0.frame.height >= 500
        }) else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard !onScreen, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        var frame = window.frame
        let visible = screen.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.menuStatusText)
        Divider()
        Button(L10n.text("Open VaultSSH")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.hasSession || model.isBusy {
            Button(L10n.text("Lock")) { model.lock() }
        }
        SettingsLink { Text(L10n.text("Settings…")) }
        Divider()
        Button(L10n.text("Quit")) { NSApp.terminate(nil) }
    }
}

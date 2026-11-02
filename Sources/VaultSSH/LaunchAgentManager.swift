import Foundation
import ServiceManagement
import Darwin

enum LaunchAgentManager {
    static let label = "cc.ryanc.VaultSSH"
    private static var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: legacyPlist.path) && legacyIsLoaded
    }
    private static var legacyIsLoaded: Bool {
        (try? launchctl(["print", "gui/\(getuid())/\(label)"])) != nil
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled && !needsApproval {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled || needsApproval {
            try SMAppService.mainApp.unregister()
        }
        // Migrate only when the user changes this preference. Do not bootout:
        // the legacy job may own this very app process.
        if FileManager.default.fileExists(atPath: legacyPlist.path) {
            if legacyIsLoaded { try launchctl(["disable", "gui/\(getuid())/\(label)"]) }
            try FileManager.default.removeItem(at: legacyPlist)
        }
    }
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func launchctl(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw CLIError.failed(L10n.text("Could not configure launch at login (%@): %@", String(process.terminationStatus), String(detail)))
        }
    }
}

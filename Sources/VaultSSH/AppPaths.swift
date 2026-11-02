import Foundation

enum AppPaths {
    static let support: URL = {
        if ProcessInfo.processInfo.environment["VAULTSSH_MOCK_KEY"] != nil,
           let path = ProcessInfo.processInfo.environment["VAULTSSH_DATA_DIR"] {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VaultSSH", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return dir
    }()

    static var socket: URL { support.appendingPathComponent("agent.sock") }
    static var status: URL { support.appendingPathComponent("status.json") }
    static var events: URL { support.appendingPathComponent("events.jsonl") }
    static var helperLog: URL { support.appendingPathComponent("helper.log") }
    static var pidFile: URL { support.appendingPathComponent("agent.pid") }
    static var tools: URL { support.appendingPathComponent("tools", isDirectory: true) }
    static var localCLI: URL { tools.appendingPathComponent("node_modules/.bin/bw") }
}

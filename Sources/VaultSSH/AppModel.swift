import Foundation
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var cliPath: String?
    @Published private(set) var cliVersion: String?
    @Published private(set) var cliProblem: String?
    @Published private(set) var bwStatus: BWStatus?
    @Published private(set) var isUnlocking = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDetecting = false
    @Published private(set) var hasSession = false
    @Published var errorMessage: String?
    @Published var installLog = ""
    @Published var isInstalling = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchNeedsApproval = false
    @Published private(set) var bwPathOverride: String
    @Published private(set) var connectionCheck: String?
    @Published private(set) var isCheckingConnection = false

    let agent: AgentController
    private let services: AppServices
    private let preferences: UserDefaults
    private var session: String?
    private var bootstrapped = false
    private var operation = UUID()
    private var unlockTask: Task<String, Error>?
    private var detection = UUID()
    private var agentCancellable: AnyCancellable?
    static let approvalGraceSeconds = 300
    static let approvalGraceLabel = L10n.text("5 minutes")

    init(services: AppServices = AppServices(), preferences: UserDefaults = .standard,
         agent: AgentController? = nil) {
        self.services = services
        self.preferences = preferences
        self.agent = agent ?? AgentController(preferences: preferences)
        bwPathOverride = preferences.string(forKey: "bwPathOverride") ?? ""
        agentCancellable = self.agent.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var pendingApproval: ApprovalRequest? { agent.pendingApproval }
    var isBusy: Bool { isUnlocking || isRefreshing || agent.isStarting }
    var isMockMode: Bool { ProcessInfo.processInfo.environment["VAULTSSH_MOCK_KEY"] != nil }
    var cliReady: Bool { isMockMode || (cliVersion.map(BitwardenCLI.isSupported) ?? false) }
    var loginCommand: String { "\(Self.shellQuote(cliPath ?? "bw")) login" }
    var sshConfiguration: String { "Host *\n  IdentityAgent \"\(agent.socketPath)\"\n" }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var menuBarSymbol: String {
        if pendingApproval != nil { return "exclamationmark.circle.fill" }
        switch agent.status.state {
        case "ready": return "key.horizontal.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "lock.fill"
        }
    }
    var stateTitle: String {
        if isUnlocking { return L10n.text("Unlocking") }
        switch agent.status.state {
        case "ready": return L10n.text("Unlocked")
        case "starting": return L10n.text("Starting")
        case "loading": return L10n.text("Loading Keys")
        case "error": return L10n.text("Needs Attention")
        default: return L10n.text("Locked")
        }
    }
    var menuStatusText: String {
        if pendingApproval != nil { return L10n.text("Waiting for SSH approval") }
        return agent.status.state == "ready" ? L10n.text("Unlocked · %ld keys", agent.keys.count) : stateTitle
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let token = operation
        if isMockMode {
            cliVersion = L10n.text("Demo mode")
            session = "mock"
            hasSession = true
            await agent.start(session: "mock", bwPath: "bw")
            return
        }
        refreshLaunchStatus()
        await refreshCLI()
        guard token == operation else { return }
        await refreshBWStatus()
        guard token == operation, !preferences.bool(forKey: "sessionRestoreDisabled") else { return }
        do {
            session = try services.loadSession()
            hasSession = session != nil
            await retryStartIfPossible()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCLI() async {
        guard !isMockMode else { return }
        let request = UUID()
        detection = request
        isDetecting = true
        defer { if detection == request { isDetecting = false } }
        let resolved = await services.resolveCLI(bwPathOverride)
        guard request == detection else { return }
        cliPath = resolved?.path
        cliVersion = resolved?.version
        bwStatus = nil
        guard let resolved else { cliProblem = L10n.text("No usable Bitwarden CLI found. Install it or check the custom path."); return }
        cliProblem = BitwardenCLI.isSupported(resolved.version) ? nil : L10n.text("This CLI version is too old. Version %@ or later is required.", String(BitwardenCLI.minimumVersion))
    }

    func refreshBWStatus() async {
        guard let path = cliPath, cliReady else { return }
        let request = detection
        do {
            let value = try await services.status(path)
            guard request == detection, path == cliPath else { return }
            bwStatus = value
        } catch {
            guard request == detection else { return }
            bwStatus = nil
            errorMessage = L10n.text("Could not read CLI login status: %@", String(error.localizedDescription))
        }
    }

    func detectAndRetry() async {
        let token = operation
        await refreshCLI()
        guard operation == token else { return }
        await refreshBWStatus()
        guard operation == token else { return }
        await retryStartIfPossible()
    }

    func saveCLIPath(_ path: String) async {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != bwPathOverride else {
            await detectAndRetry()
            return
        }
        bwPathOverride = value
        preferences.set(value, forKey: "bwPathOverride")
        // Changing CLI can change accounts. Require a fresh unlock instead of
        // carrying an old vault session into the new executable.
        lock()
        await refreshCLI()
        await refreshBWStatus()
    }

    func retryStartIfPossible() async {
        guard !isBusy, cliReady, let session, let cliPath, agent.status.state != "ready" else { return }
        let token = operation
        await agent.start(session: session, bwPath: cliPath)
        guard operation == token else { return }
        if agent.status.state == "error" { errorMessage = agent.status.error }
    }

    func unlock(password: String) async {
        guard !isBusy, !password.isEmpty, let cliPath, cliReady else { return }
        operation = UUID()
        let token = operation
        isUnlocking = true
        errorMessage = nil
        defer { if operation == token { isUnlocking = false; unlockTask = nil } }
        do {
            let task = Task { try await services.unlock(cliPath, password) }
            unlockTask = task
            let value = try await task.value
            guard operation == token, !Task.isCancelled else { return }
            guard !value.isEmpty else { throw CLIError.failed(L10n.text("The CLI returned no session. Please retry.")) }
            agent.stop()
            session = nil
            hasSession = false
            try services.saveSession(value)
            preferences.set(false, forKey: "sessionRestoreDisabled")
            session = value
            hasSession = true
            await refreshBWStatus()
            guard operation == token, !Task.isCancelled else { return }
            await agent.start(session: value, bwPath: cliPath)
            guard operation == token else { return }
            if agent.status.state == "error" { errorMessage = agent.status.error }
        } catch {
            guard operation == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func lock() {
        operation = UUID()
        unlockTask?.cancel()
        unlockTask = nil
        session = nil
        hasSession = false
        isUnlocking = false
        isRefreshing = false
        connectionCheck = nil
        agent.stop()
        guard !isMockMode else { return }
        // Persist before deletion: a denied Keychain deletion must not restore
        // the session automatically the next time the app launches.
        preferences.set(true, forKey: "sessionRestoreDisabled")
        do { try services.deleteSession() }
        catch { errorMessage = L10n.text("The agent is locked; %@. Automatic session restore is disabled.", String(error.localizedDescription)) }
    }

    func refreshKeys() async {
        guard !isBusy, let session else { return }
        let token = operation
        isRefreshing = true
        defer { if operation == token { isRefreshing = false } }
        await agent.start(session: session, bwPath: cliPath ?? "bw")
        guard operation == token else { return }
        if agent.status.state == "error" { errorMessage = agent.status.error }
    }

    func checkConnection() async {
        guard !isCheckingConnection else { return }
        let token = operation
        let socket = agent.socketPath
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        let result = await Task.detached { () -> String in
            do {
                let cli = BitwardenCLI(path: "/usr/bin/ssh-add")
                _ = try cli.run(["-l"], extraEnv: ["SSH_AUTH_SOCK": socket], timeout: 10)
                return L10n.text("Connected. SSH clients can list keys. Save the configuration above to ~/.ssh/config.")
            } catch { return L10n.text("Connection failed: %@", String(error.localizedDescription)) }
        }.value
        guard token == operation else { return }
        connectionCheck = result
    }

    func refreshLaunchStatus() {
        guard !isMockMode else { return }
        launchAtLogin = LaunchAgentManager.isEnabled
        launchNeedsApproval = LaunchAgentManager.needsApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isMockMode else { return }
        do { try LaunchAgentManager.setEnabled(enabled) }
        catch { errorMessage = L10n.text("Could not configure launch at login: %@", String(error.localizedDescription)) }
        refreshLaunchStatus()
    }

    func installCompatibleCLI() async {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = L10n.text("Installing @bitwarden/cli@%@ in\n%@\n\n", String(BitwardenCLI.compatibleVersion), String(AppPaths.tools.path))
        defer { isInstalling = false }

        let npmPath = await Task.detached { BitwardenCLI.shellWhich("npm") }.value
        guard let npmPath else {
            installLog += L10n.text("npm was not found. Install Node.js first, or run: brew install bitwarden-cli\n")
            return
        }

        let toolsPath = AppPaths.tools.path
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: npmPath)
            process.arguments = [
                "install",
                "--prefix", toolsPath,
                "--no-fund",
                "--no-audit",
                "--save-exact",
                "@bitwarden/cli@\(BitwardenCLI.compatibleVersion)"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = BitwardenCLI.loginPATH
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, L10n.text("Could not start npm: %@\n", String(error.localizedDescription)))
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value

        installLog += result.1
        if result.0 == 0 {
            installLog += L10n.text("\nInstallation complete.\n")
            await refreshCLI()
            await refreshBWStatus()
        } else {
            installLog += L10n.text("\nInstallation failed (exit code %@).\n", String(result.0))
        }
    }

    func shutdown() {
        operation = UUID()
        unlockTask?.cancel()
        unlockTask = nil
        agent.stop()
    }
}

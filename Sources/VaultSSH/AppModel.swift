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
    @Published private(set) var unlockProgress = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDetecting = false
    @Published private(set) var hasSession = false
    @Published var errorMessage: String?
    @Published var installLog = ""
    @Published var isInstalling = false
    @Published private(set) var systemUnlockEnabled: Bool
    @Published private(set) var pinEnabled = false
    @Published private(set) var idleLockMinutes: Int
    @Published var showsUnlockPanel = false
    @Published private(set) var isConfiguringUnlock = false
    private var pinSession: PINSession?
    private var systemContext: SystemUnlockContext?
    private var listenerEnabled = false
    private var activeUnlockRequest: String?
    private var unlockCancellable: AnyCancellable?
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
        systemUnlockEnabled = preferences.bool(forKey: "systemUnlockEnabled")
        idleLockMinutes = preferences.integer(forKey: "idleLockMinutes")
        bwPathOverride = preferences.string(forKey: "bwPathOverride") ?? ""
        agentCancellable = self.agent.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        unlockCancellable = self.agent.$unlockRequest.sink { [weak self] request in
            guard request == nil, let requestID = self?.activeUnlockRequest else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeUnlockRequest == requestID, self.agent.unlockRequest == nil,
                      self.agent.status.state != "ready" else { return }
                self.cancelUnlock()
            }
        }
    }

    var pendingApproval: ApprovalRequest? { agent.pendingApproval }
    var isBusy: Bool { isUnlocking || isRefreshing || isInstalling || isConfiguringUnlock || agent.isStarting }
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
    var loadingProgress: String {
        agent.status.phase == "syncing" ? L10n.text("Syncing vault…") : L10n.text("Loading SSH keys…")
    }
    var unlockProgressTitle: String {
        agent.isStarting ? loadingProgress : unlockProgress
    }
    var stateTitle: String {
        if isUnlocking { return unlockProgressTitle }
        if isRefreshing { return loadingProgress }
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
        if isMockMode {
            cliVersion = L10n.text("Demo mode")
            cliPath = "bw"
            session = "mock"
            hasSession = true
            await agent.start(session: "mock", bwPath: "bw")
            return
        }
        lock() // Remove legacy persisted sessions; every launch requires a fresh unlock.
        let bootstrapToken = operation
        refreshLaunchStatus()
        await refreshCLI()
        guard bootstrapToken == operation else { return }
        await refreshBWStatus()
    }

    func refreshCLI() async {
        guard !isMockMode else { return }
        let request = UUID()
        detection = request
        isDetecting = true
        defer {
            if detection == request {
                isDetecting = false
                if listenerEnabled { Task { await listenWhileLocked() } }
            }
        }
        let resolved = await services.resolveCLI(bwPathOverride)
        guard request == detection else { return }
        if let previous = cliPath, previous != resolved?.path {
            forgetQuickUnlock()
            lock()
        }
        cliPath = resolved?.path
        cliVersion = resolved?.version
        bwStatus = nil
        guard let resolved else { cliProblem = L10n.text("No usable Bitwarden CLI found. Install it or check the custom path."); return }
        cliProblem = BitwardenCLI.isSupported(resolved.version) ? nil : L10n.text("Secure access requires the npm CLI version %@.", String(BitwardenCLI.compatibleVersion))
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
        forgetQuickUnlock()
        lock()
        await refreshCLI()
        await refreshBWStatus()
    }

    func retryStartIfPossible() async {
        guard !isBusy, cliReady, let cliPath, agent.status.state != "ready" else { return }
        guard let session else { await listenWhileLocked(); return }
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
        unlockProgress = L10n.text("Verifying vault password…")
        activeUnlockRequest = agent.unlockRequest?.id
        errorMessage = nil
        defer { if operation == token { isUnlocking = false; unlockTask = nil; activeUnlockRequest = nil } }
        do {
            let task = Task { try await services.unlock(cliPath, password) }
            unlockTask = task
            let value = try await task.value
            guard operation == token, !Task.isCancelled else { return }
            guard !value.isEmpty else { throw CLIError.failed(L10n.text("The CLI returned no session. Please retry.")) }
            pinSession = nil
            pinEnabled = false
            session = nil
            hasSession = false
            session = value
            hasSession = true
            unlockProgress = L10n.text("Checking vault account…")
            await refreshBWStatus()
            guard operation == token, !Task.isCancelled else { return }
            if systemUnlockEnabled {
                do { try await services.saveQuickSession(savedSession(value)) }
                catch {
                    systemUnlockEnabled = false
                    preferences.set(false, forKey: "systemUnlockEnabled")
                    errorMessage = error.localizedDescription
                }
                if !systemUnlockEnabled { try? services.deleteQuickSession() }
                guard operation == token, !Task.isCancelled else { return }
            }
            unlockProgress = L10n.text("Loading SSH keys…")
            await agent.resume(session: value, bwPath: cliPath, requestID: activeUnlockRequest)
            guard operation == token else { return }
            if agent.status.state != "ready" {
                session = nil
                hasSession = false
                errorMessage = agent.status.error
            } else { showsUnlockPanel = false }
        } catch {
            guard operation == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func lock() {
        operation = UUID()
        unlockTask?.cancel()
        unlockTask = nil
        systemContext?.cancel()
        systemContext = nil
        activeUnlockRequest = nil
        showsUnlockPanel = false
        session = nil
        hasSession = false
        isUnlocking = false
        isRefreshing = false
        connectionCheck = nil
        agent.stop()
        if listenerEnabled { Task { await listenWhileLocked() } }
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
        await agent.start(session: session, bwPath: cliPath ?? "bw", syncVault: true)
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
        lock()
        isInstalling = true
        installLog = L10n.text("Installing @bitwarden/cli@%@ in\n%@\n\n", String(BitwardenCLI.compatibleVersion), String(AppPaths.tools.path))
        defer { isInstalling = false; if listenerEnabled { Task { await listenWhileLocked() } } }

        let npmPath = await Task.detached { BitwardenCLI.shellWhich("npm") }.value
        guard let npmPath else {
            installLog += L10n.text("npm was not found. Install Node.js and npm first.\n")
            return
        }

        let toolsPath = AppPaths.tools.path
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: npmPath)
            process.arguments = [
                "ci",
                "--no-fund",
                "--no-audit"
            ]
            process.environment = BitwardenCLI.cleanEnvironment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                let directory = URL(fileURLWithPath: toolsPath)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in ["package.json", "package-lock.json"] {
                    let source = Bundle.module.resourceURL!.appendingPathComponent("CLI").appendingPathComponent(name)
                    try Data(contentsOf: source).write(to: directory.appendingPathComponent(name), options: .atomic)
                }
                process.currentDirectoryURL = directory
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

    func automaticLock() {
        guard hasSession || isUnlocking || isRefreshing || agent.isStarting || agent.unlockRequest != nil || showsUnlockPanel else { return }
        lock()
    }

    func shutdown() {
        listenerEnabled = false
        pinSession = nil
        pinEnabled = false
        lock()
    }

    func enableRequestListener() async {
        listenerEnabled = true
        await listenWhileLocked()
    }

    private func listenWhileLocked() async {
        guard listenerEnabled, !hasSession, !isUnlocking, !isInstalling, !isDetecting, !agent.helperRunning,
              cliReady, let cliPath else { return }
        await agent.start(session: "", bwPath: cliPath, locked: true)
    }

    func setIdleLockMinutes(_ minutes: Int) {
        guard [0, 5, 15, 30, 60].contains(minutes) else { return }
        idleLockMinutes = minutes
        preferences.set(minutes, forKey: "idleLockMinutes")
    }

    private func savedSession(_ value: String) -> SavedSession {
        SavedSession(session: value, cliPath: URL(fileURLWithPath: cliPath ?? "bw").resolvingSymlinksInPath().path,
                     email: bwStatus?.userEmail, server: bwStatus?.serverUrl)
    }

    func setPIN(_ pin: String, confirmation: String) {
        guard hasSession, !isBusy, let session else { return }
        guard pin == confirmation else { errorMessage = L10n.text("The PINs do not match."); return }
        do {
            pinSession = try PINSession(pin: pin, session: savedSession(session))
            pinEnabled = true
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func disablePIN() { pinSession = nil; pinEnabled = false }

    func enableSystemUnlock() async {
        guard hasSession, !isBusy, let session else { return }
        let token = operation
        isConfiguringUnlock = true
        defer { isConfiguringUnlock = false }
        do {
            try await services.saveQuickSession(savedSession(session))
            guard operation == token, hasSession else { try? services.deleteQuickSession(); return }
            systemUnlockEnabled = true
            preferences.set(true, forKey: "systemUnlockEnabled")
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func disableSystemUnlock() {
        if systemContext != nil { cancelUnlock() }
        systemContext?.cancel()
        systemUnlockEnabled = false
        preferences.set(false, forKey: "systemUnlockEnabled")
        do { try services.deleteQuickSession() }
        catch { errorMessage = error.localizedDescription }
    }

    private func forgetQuickUnlock() {
        disablePIN()
        if systemUnlockEnabled { disableSystemUnlock() }
    }

    func unlockWithPIN(_ pin: String) async {
        guard !isBusy, pinEnabled else { return }
        do {
            let saved = try pinSession!.unlock(pin: pin)
            await quickUnlock { saved }
        } catch {
            pinEnabled = pinSession?.isAvailable == true
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithSystem() async {
        guard !isBusy, systemUnlockEnabled else { return }
        let context = SystemUnlockContext()
        systemContext = context
        defer { context.cancel(); if systemContext === context { systemContext = nil } }
        await quickUnlock { try await self.services.loadQuickSession(context) }
    }

    private func quickUnlock(_ load: () async throws -> SavedSession) async {
        guard !isBusy, cliReady, let cliPath else { return }
        operation = UUID()
        let token = operation
        activeUnlockRequest = agent.unlockRequest?.id
        isUnlocking = true
        unlockProgress = L10n.text("Authenticating…")
        errorMessage = nil
        defer { if operation == token { isUnlocking = false; activeUnlockRequest = nil } }
        do {
            let saved = try await load()
            guard operation == token else { return }
            if !isMockMode {
                unlockProgress = L10n.text("Checking vault account…")
                let status = try await services.status(cliPath)
                guard operation == token else { return }
                bwStatus = status
                guard saved.matches(path: cliPath, status: status) else {
                    forgetQuickUnlock()
                    errorMessage = L10n.text("Your CLI account changed. Unlock with your vault password.")
                    return
                }
            }
            session = saved.session
            hasSession = true
            unlockProgress = L10n.text("Loading SSH keys…")
            await agent.resume(session: saved.session, bwPath: cliPath, requestID: activeUnlockRequest)
            guard operation == token else { return }
            if agent.status.state == "ready" { showsUnlockPanel = false }
            else {
                session = nil
                hasSession = false
                errorMessage = agent.status.error ?? L10n.text("Unlock failed. Try your vault password.")
            }
        } catch is CancellationError {
            if operation == token { errorMessage = nil }
        } catch {
            if operation == token { errorMessage = error.localizedDescription }
        }
    }

    func cancelUnlock() {
        operation = UUID()
        unlockTask?.cancel()
        unlockTask = nil
        systemContext?.cancel()
        systemContext = nil
        activeUnlockRequest = nil
        isUnlocking = false
        session = nil
        hasSession = false
        showsUnlockPanel = false
        agent.cancelUnlockRequest()
        if agent.status.state == "loading" || agent.status.state == "ready" { lock() }
    }
}

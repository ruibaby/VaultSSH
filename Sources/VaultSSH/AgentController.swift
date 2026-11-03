import Foundation
import Combine
import Darwin

@MainActor
final class AgentController: ObservableObject {
    @Published private(set) var status: AgentStatus = .stopped
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var helperRunning = false
    @Published private(set) var approvals: [ApprovalRequest] = []
    @Published private(set) var unlockRequest: ApprovalRequest?
    @Published private(set) var notice: String?

    private var process: Process?
    private var input: FileHandle?
    private var logHandle: FileHandle?
    private var termination: Task<Void, Never>?
    private var generation = UUID()
    private let maxEvents = 500
    private let preferences: UserDefaults

    init(loadHistory: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if loadHistory {
            let url = AppPaths.events
            Task { [weak self] in
                let history = await Task.detached {
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return [AgentEvent]() }
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? 0
                    let offset = size > 512_000 ? size - 512_000 : 0
                    try? handle.seek(toOffset: offset)
                    guard let data = try? handle.readToEnd() else { return [AgentEvent]() }
                    var lines = data.split(separator: 0x0A)
                    if offset > 0 && !lines.isEmpty { lines.removeFirst() }
                    return lines.compactMap { try? JSONDecoder().decode(AgentEvent.self, from: Data($0)) }.suffix(500).map { $0 }
                }.value
                guard let self else { return }
                let combined = history + self.events
                var seen = Set<String>()
                self.events = Array(combined.filter { seen.insert($0.id).inserted }.suffix(self.maxEvents))
            }
        }
    }

    var socketPath: String { AppPaths.socket.path }
    var keys: [KeyInfo] { status.keys ?? [] }
    var pendingApproval: ApprovalRequest? { approvals.first }
    var isStarting: Bool { status.state == "starting" || status.state == "loading" }

    func start(session: String, bwPath: String, locked: Bool = false, syncVault: Bool = false) async {
        stop()
        let run = generation
        await termination?.value
        guard generation == run, !Task.isCancelled else { return }
        guard let helper = helperURL() else {
            fail(L10n.text("The bundled bwssh-agent is missing. Rebuild the app."))
            return
        }
        status = AgentStatus(state: "starting")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--socket", AppPaths.socket.path, "--status", AppPaths.status.path,
                             "--events", AppPaths.events.path, "--bw", bwPath]
        if locked { process.arguments! += ["--locked"] }
        if syncVault { process.arguments! += ["--sync"] }
        if let mockKey = ProcessInfo.processInfo.environment["VAULTSSH_MOCK_KEY"] {
            process.arguments! += ["--mock-key", mockKey]
        }
        if ProcessInfo.processInfo.environment["VAULTSSH_MOCK_KEY"] == nil {
            guard let node = BitwardenCLI.nodePath, let bridge = BitwardenCLI.bridgeURL else {
                fail(L10n.text("Install Node.js and the supported npm CLI to use secure vault access."))
                return
            }
            process.arguments! += ["--node", node, "--bridge", bridge.path]
        }
        var environment = BitwardenCLI.cleanEnvironment
        environment["VAULTSSH_LANGUAGE"] = L10n.language
        environment.removeValue(forKey: "BW_SESSION")
        environment.removeValue(forKey: "BW_PASSWORD")
        process.environment = environment
        let commands = Pipe()
        let messages = Pipe()
        process.standardInput = commands
        process.standardOutput = messages
        logHandle = openHelperLog()
        process.standardError = logHandle
        do {
            try process.run()
            self.process = process
            input = commands.fileHandleForWriting
            _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            helperRunning = true
            try send(ControlCommand(type: "session", session: session,
                                    keyOrder: preferences.stringArray(forKey: "keyOrder") ?? []))
        } catch {
            stop()
            fail(L10n.text("Could not start the agent: %@", String(error.localizedDescription)))
            return
        }

        let output = messages.fileHandleForReading
        Task.detached { [weak self] in
            defer { try? output.close() }
            do {
                try await ControlStream.read(from: output) { [weak self] message in
                    await self?.receive(message, run: run)
                }
                await self?.disconnected(run: run)
            } catch {
                await self?.disconnected(run: run, error: error.localizedDescription)
            }
        }

        let deadline = Date().addingTimeInterval(160)
        while generation == run && !Task.isCancelled && Date() < deadline {
            if status.state == "ready" || status.state == "locked" || status.state == "error" || !helperRunning { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == run else { return }
        stop()
        if !Task.isCancelled { fail(L10n.text("Loading keys timed out. Check your CLI login and network, then retry.")) }
    }

    func resume(session: String, bwPath: String, requestID: String?) async {
        if let requestID, unlockRequest?.id != requestID { return }
        if !helperRunning || status.state != "locked" {
            await start(session: session, bwPath: bwPath)
            return
        }
        let run = generation
        status = AgentStatus(state: "loading")
        do { try send(ControlCommand(type: "unlock", session: session, id: requestID)) }
        catch { stop(); fail(error.localizedDescription); return }
        let deadline = Date().addingTimeInterval(160)
        while generation == run && !Task.isCancelled && Date() < deadline {
            if status.state != "loading" { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == run else { return }
        stop()
        fail(L10n.text("Loading keys timed out. Check your CLI login and network, then retry."))
    }

    func cancelUnlockRequest() {
        guard let request = unlockRequest else { return }
        do { try send(ControlCommand(type: "cancelUnlock", id: request.id)) }
        catch { stop() }
        unlockRequest = nil
    }

    // Invalidate callbacks before any asynchronous teardown. A new start waits
    // for this owned process to exit; it never unlinks another helper's socket.
    func stop() {
        generation = UUID()
        try? input?.close()
        input = nil
        if let process, process.isRunning {
            process.terminate()
            termination = Task.detached {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        helperRunning = false
        approvals = []
        unlockRequest = nil
        status = .stopped
        notice = nil
    }

    func decideApproval(id: String, allow: Bool, graceSeconds: Int) {
        guard approvals.contains(where: { $0.id == id }) else { return }
        do {
            try send(ControlCommand(type: "decision", decision: ApprovalDecision(
                id: id, allow: allow, graceSeconds: allow ? min(max(0, graceSeconds), 300) : 0
            )))
            approvals.removeAll { $0.id == id }
        } catch {
            stop()
            fail(L10n.text("Could not send the signing decision. The agent is locked: %@", String(error.localizedDescription)))
        }
    }

    func revokeApprovals() {
        do { try send(ControlCommand(type: "revoke")) }
        catch { stop(); fail(L10n.text("Could not revoke approvals. The agent is locked.")) }
    }

    func moveKey(_ key: KeyInfo, to destination: Int) {
        var ordered = keys
        guard status.state == "ready", ordered.indices.contains(destination),
              let source = ordered.firstIndex(where: { $0.id == key.id }), source != destination else { return }
        ordered.insert(ordered.remove(at: source), at: destination)
        var fingerprints = ordered.map(\.fingerprint)
        // Keep preferences for temporarily missing keys (for example offline
        // sync or a partial load) without exposing them through the agent.
        fingerprints += (preferences.stringArray(forKey: "keyOrder") ?? []).filter { !fingerprints.contains($0) }
        do {
            try send(ControlCommand(type: "keyOrder", keyOrder: fingerprints))
            preferences.set(fingerprints, forKey: "keyOrder")
        } catch {
            notice = L10n.text("Could not update key order. Refresh your keys and retry.")
        }
    }

    private func send(_ command: ControlCommand) throws {
        guard let input else { throw CLIError.failed(L10n.text("The approval channel is closed.")) }
        var data = try JSONEncoder().encode(command)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ message: ControlEvent, run: UUID) {
        guard generation == run else { return }
        switch message.type {
        case "unlock": unlockRequest = message.request
        case "unlockDismiss":
            if unlockRequest?.id == message.id { unlockRequest = nil }
        case "status":
            if let status = message.status { self.status = status }
        case "keys":
            if let keys = message.keys, status.state == "ready" {
                status.keys = keys
                notice = L10n.text("Key order saved for future SSH connections")
            }
        case "approval":
            if let request = message.request, !approvals.contains(where: { $0.id == request.id }) {
                approvals.append(request)
            }
        case "dismiss": approvals.removeAll { $0.id == message.id }
        case "revoked": notice = L10n.text("Temporary approvals revoked. The next signature will require approval.")
        case "event":
            if let event = message.event {
                events.append(event)
                if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
            }
        default: break
        }
    }

    private func disconnected(run: UUID, error: String? = nil) {
        guard generation == run else { return }
        let previousError = status.state == "error" ? status.error : nil
        stop()
        fail(previousError ?? error ?? L10n.text("The agent exited. Unlock again or retry."))
    }

    private func fail(_ message: String) {
        status = AgentStatus(state: "error", error: message)
    }

    private func helperURL() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bwssh-agent")
    }

    private func openHelperLog() -> FileHandle {
        let url = AppPaths.helperLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                          attributes: [.posixPermissions: NSNumber(value: 0o600)])
        }
        let handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
        _ = try? handle.seekToEnd()
        return handle
    }
}

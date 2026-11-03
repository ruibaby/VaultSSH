import XCTest
@testable import VaultSSH

private actor Gate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func resume(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(_ services: AppServices) -> (AppModel, UserDefaults) {
        let suite = "VaultSSHTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (AppModel(services: services, preferences: prefs, agent: AgentController(loadHistory: false)), prefs)
    }
    private func services() -> AppServices {
        AppServices(deleteSession: {},
                    resolveCLI: { path in (path.isEmpty ? "/fake/bw" : path, "2026.2.0") },
                    status: { _ in BWStatus(status: "locked", userEmail: nil, serverUrl: nil, lastSync: nil) },
                    unlock: { _, _ in "fake-session" })
    }
    private func waitFor<Value>(_ gate: Gate<Value>) async {
        for _ in 0..<1_000 {
            if await gate.waiting { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("operation never reached suspension point")
    }

    func testAutomaticLockWhileUnlockingDoesNotStart() async {
        let gate = Gate<String>()
        var service = services()
        service.unlock = { _, _ in await gate.wait() }
        let (model, preferences) = makeModel(service)
        await model.refreshCLI()
        let pending = Task { await model.unlock(password: "test") }
        await waitFor(gate)
        model.automaticLock()
        await gate.resume("late-session")
        await pending.value
        XCTAssertFalse(model.hasSession)
        XCTAssertFalse(model.isUnlocking)
        XCTAssertEqual(model.agent.status.state, "stopped")
        XCTAssertTrue(preferences.bool(forKey: "sessionRestoreDisabled"))
    }

    func testAutomaticLockDuringStatusRefreshDoesNotRestartAgent() async {
        let gate = Gate<BWStatus>()
        var service = services()
        service.status = { _ in await gate.wait() }
        let (model, _) = makeModel(service)
        await model.refreshCLI()
        let pending = Task { await model.unlock(password: "test") }
        await waitFor(gate)
        XCTAssertTrue(model.hasSession)
        model.automaticLock()
        await gate.resume(BWStatus(status: "locked", userEmail: nil, serverUrl: nil, lastSync: nil))
        await pending.value
        XCTAssertFalse(model.hasSession)
        XCTAssertEqual(model.agent.status.state, "stopped")
    }

    func testBootstrapDeletesLegacySessionAndStaysLocked() async {
        var deletions = 0
        var service = services()
        service.deleteSession = { deletions += 1 }
        let (model, preferences) = makeModel(service)
        await model.bootstrap()
        XCTAssertEqual(deletions, 1)
        XCTAssertTrue(preferences.bool(forKey: "sessionRestoreDisabled"))
        XCTAssertFalse(model.hasSession)
        XCTAssertEqual(model.agent.status.state, "stopped")
    }

    func testFailedKeychainDeleteStillLocksAndDisablesRestore() {
        var service = services()
        service.deleteSession = { throw CLIError.failed("delete denied") }
        let (model, preferences) = makeModel(service)
        model.lock()
        XCTAssertFalse(model.hasSession)
        XCTAssertEqual(model.agent.status.state, "stopped")
        XCTAssertTrue(preferences.bool(forKey: "sessionRestoreDisabled"))
        XCTAssertTrue(model.errorMessage?.contains("delete denied") == true)
    }

    func testDuplicateUnlockDoesNotStartAnotherOperation() async {
        let gate = Gate<String>()
        var calls = 0
        var service = services()
        service.unlock = { _, _ in calls += 1; return await gate.wait() }
        let (model, _) = makeModel(service)
        await model.refreshCLI()
        let first = Task { await model.unlock(password: "first") }
        await waitFor(gate)
        await model.unlock(password: "second")
        XCTAssertEqual(calls, 1)
        model.automaticLock()
        await gate.resume("late-session")
        await first.value
    }

    func testSavingCLIPathPersistsAndBuildsQuotedLoginCommand() async {
        let (model, preferences) = makeModel(services())
        let path = "/tmp/owner's tools/bw"
        await model.saveCLIPath(path)
        XCTAssertEqual(preferences.string(forKey: "bwPathOverride"), path)
        XCTAssertEqual(model.cliPath, path)
        XCTAssertEqual(model.loginCommand, "'/tmp/owner'\\''s tools/bw' login")
    }

    func testCustomCLIPathDoesNotFallBackToAnotherAccount() {
        XCTAssertEqual(BitwardenCLI.candidatePaths(override: "/missing/bw"), ["/missing/bw"])
    }

    func testSavingUnchangedCLIPathDoesNotDeleteSession() async {
        var deletions = 0
        var service = services()
        service.deleteSession = { deletions += 1 }
        let (model, preferences) = makeModel(service)
        await model.saveCLIPath("  \n")
        XCTAssertEqual(deletions, 0)
        XCTAssertFalse(preferences.bool(forKey: "sessionRestoreDisabled"))
        XCTAssertEqual(model.cliPath, "/fake/bw")
    }
}

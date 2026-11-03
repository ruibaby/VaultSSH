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
        AppServices(savePIN: { _ in }, loadPIN: { nil }, deletePIN: {}, deleteSession: {},
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

    func testSavedPINDoesNotUnlockOrReadKeychainOnLaunch() async {
        var reads = 0, deletions = 0
        var service = services()
        service.loadPIN = { reads += 1; return nil }
        service.deletePIN = { deletions += 1 }
        let (_, preferences) = makeModel(service)
        preferences.set(true, forKey: "pinConfigured")
        let model = AppModel(services: service, preferences: preferences, agent: AgentController(loadHistory: false))
        await model.bootstrap()
        XCTAssertTrue(model.pinConfigured)
        XCTAssertFalse(model.pinEnabled)
        XCTAssertFalse(model.hasSession)
        model.shutdown()
        XCTAssertTrue(preferences.bool(forKey: "pinConfigured"))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(deletions, 0)
    }

    func testFailedMasterPasswordDoesNotLoadSavedPIN() async {
        var reads = 0
        var service = services()
        service.unlock = { _, _ in throw CLIError.failed("wrong password") }
        service.loadPIN = { reads += 1; return nil }
        let (model, _) = makeModel(service)
        await model.refreshCLI()
        await model.unlock(password: "wrong")
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(model.pinEnabled)
        XCTAssertFalse(model.hasSession)
    }

    func testDisablePINDeletesSavedConfiguration() async {
        var deletions = 0
        var service = services()
        service.deletePIN = { deletions += 1 }
        let (_, preferences) = makeModel(service)
        preferences.set(true, forKey: "pinConfigured")
        let model = AppModel(services: service, preferences: preferences, agent: AgentController(loadHistory: false))
        await model.disablePIN()
        XCTAssertEqual(deletions, 1)
        XCTAssertFalse(model.pinConfigured)
        XCTAssertFalse(preferences.bool(forKey: "pinConfigured"))
    }

    func testAutomaticLockWhileUnlockingDoesNotStart() async {
        let gate = Gate<String>()
        var service = services()
        service.unlock = { _, _ in await gate.wait() }
        let (model, preferences) = makeModel(service)
        await model.refreshCLI()
        let pending = Task { await model.unlock(password: "test") }
        await waitFor(gate)
        XCTAssertEqual(model.unlockProgressTitle, L10n.text("Verifying vault password…"))
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
        XCTAssertEqual(model.unlockProgressTitle, L10n.text("Checking vault account…"))
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
    func testCancelledSystemAuthenticationCannotRestoreSession() async {
        let gate = Gate<SavedSession>()
        var service = services()
        service.loadQuickSession = { _ in await gate.wait() }
        let (model, preferences) = makeModel(service)
        preferences.set(true, forKey: "systemUnlockEnabled")
        // A fresh model picks up the opt-in without touching the real Keychain.
        let protected = AppModel(services: service, preferences: preferences, agent: AgentController(loadHistory: false))
        await protected.refreshCLI()
        let pending = Task { await protected.unlockWithSystem() }
        await waitFor(gate)
        protected.lock()
        await gate.resume(SavedSession(session: "late", cliPath: "/fake/bw", email: nil, server: nil))
        await pending.value
        XCTAssertFalse(protected.hasSession)
        XCTAssertEqual(protected.agent.status.state, "stopped")
        XCTAssertFalse(model.pinEnabled)
    }

    func testIdlePreferenceDefaultsToOffAndRejectsUnsupportedValues() {
        let (model, preferences) = makeModel(services())
        XCTAssertEqual(model.idleLockMinutes, 0)
        model.setIdleLockMinutes(30)
        XCTAssertEqual(preferences.integer(forKey: "idleLockMinutes"), 30)
        model.setIdleLockMinutes(-1)
        XCTAssertEqual(model.idleLockMinutes, 30)
    }

    func testAutomaticLockDismissesManualUnlockPanel() {
        let (model, _) = makeModel(services())
        model.showsUnlockPanel = true
        model.automaticLock()
        XCTAssertFalse(model.showsUnlockPanel)
        XCTAssertFalse(model.hasSession)
    }

    func testChangedAccountDisablesQuickUnlockAndExplainsWhy() async {
        var deleted = false
        var service = services()
        service.loadQuickSession = { _ in SavedSession(session: "dummy", cliPath: "/fake/bw", email: "old@example.invalid", server: nil) }
        service.deleteQuickSession = { deleted = true }
        let (_, preferences) = makeModel(service)
        preferences.set(true, forKey: "systemUnlockEnabled")
        let model = AppModel(services: service, preferences: preferences, agent: AgentController(loadHistory: false))
        await model.refreshCLI()
        await model.unlockWithSystem()
        XCTAssertTrue(deleted)
        XCTAssertFalse(model.systemUnlockEnabled)
        XCTAssertFalse(model.hasSession)
        XCTAssertFalse(model.isUnlocking)
        XCTAssertEqual(model.errorMessage, L10n.text("Your CLI account changed. Unlock with your vault password."))
    }

}

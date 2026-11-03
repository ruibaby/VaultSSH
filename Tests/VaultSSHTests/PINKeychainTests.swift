import XCTest
@testable import VaultSSH

final class PINKeychainTests: XCTestCase {
    func testLoginKeychainRoundTripAndDeletion() throws {
        guard ProcessInfo.processInfo.environment["VAULTSSH_PIN_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Opt-in test creates one disposable login-Keychain item.")
        }
        let store = PINKeychain(service: "cc.ryanc.VaultSSH.tests.pin.\(UUID().uuidString)")
        defer { try? store.delete() }
        let first = SavedSession(session: "first-disposable-session", cliPath: "/test/bw", email: "fixture@example.invalid", server: nil)
        let configured = try PINConfiguration(pin: "928461", session: first)
        try store.save(configured)
        let restored = try XCTUnwrap(PINKeychain(service: store.service).load())
        let fresh = SavedSession(session: "second-disposable-session", cliPath: first.cliPath, email: first.email, server: nil)
        var session = try PINSession(configuration: restored, session: fresh)
        XCTAssertEqual(try session.unlock(pin: "928461"), fresh)
        let replacement = try PINConfiguration(pin: "318572", session: fresh)
        try store.save(replacement)
        var changed = try PINSession(configuration: XCTUnwrap(store.load()), session: fresh)
        XCTAssertThrowsError(try changed.unlock(pin: "928461"))
        XCTAssertEqual(try changed.unlock(pin: "318572"), fresh)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}

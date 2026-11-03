import XCTest
@testable import VaultSSH

final class QuickUnlockTests: XCTestCase {
    private let saved = SavedSession(session: "disposable-session", cliPath: "/test/bw", email: "test@example.invalid", server: "https://vault.example.invalid")

    func testPINValidation() {
        for pin in ["12345", "1234567890123", "１２３４５６", "12345a", "123 45"] {
            XCTAssertFalse(PINSession.isValid(pin))
            XCTAssertThrowsError(try PINSession(pin: pin, session: saved))
        }
        XCTAssertTrue(PINSession.isValid("098765"))
    }

    func testCorrectPINRestoresSessionAndResetsFailedAttempts() throws {
        var pin = try PINSession(pin: "928461", session: saved)
        XCTAssertThrowsError(try pin.unlock(pin: "928460"))
        XCTAssertEqual(pin.attemptsRemaining, 4)
        XCTAssertEqual(try pin.unlock(pin: "928461"), saved)
        XCTAssertEqual(pin.attemptsRemaining, 5)
    }

    func testFiveFailuresDestroyPINAccessEvenWithCorrectPIN() throws {
        var pin = try PINSession(pin: "928461", session: saved)
        for _ in 0..<5 { XCTAssertThrowsError(try pin.unlock(pin: "000000")) }
        XCTAssertFalse(pin.isAvailable)
        XCTAssertThrowsError(try pin.unlock(pin: "928461"))
    }

    func testPersistedConfigurationRestoresSamePINForAFreshSession() throws {
        let original = try PINSession(pin: "928461", session: saved)
        let data = try JSONEncoder().encode(original.configuration)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "salt", "publicKey", "wrappedPrivateKey", "cliPath", "email", "server"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(saved.session))
        let stored = try JSONDecoder().decode(PINConfiguration.self, from: data)
        let fresh = SavedSession(session: "fresh-master-password-session", cliPath: saved.cliPath, email: saved.email, server: saved.server)
        var restored = try PINSession(configuration: stored, session: fresh)
        XCTAssertThrowsError(try restored.unlock(pin: "000000"))
        XCTAssertEqual(try restored.unlock(pin: "928461"), fresh)
    }

    func testConfigurationCannotBeReusedForAnotherAccount() throws {
        let configuration = try PINConfiguration(pin: "928461", session: saved)
        let other = SavedSession(session: "new", cliPath: saved.cliPath, email: "other@example.invalid", server: saved.server)
        XCTAssertThrowsError(try PINSession(configuration: configuration, session: other))
    }

    func testTamperedPINMaterialCannotUnlock() throws {
        let configuration = try PINConfiguration(pin: "928461", session: saved)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        fields["wrappedPrivateKey"] = Data(repeating: 0, count: 60).base64EncodedString()
        let tampered = try JSONDecoder().decode(PINConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
        var session = try PINSession(configuration: tampered, session: saved)
        XCTAssertThrowsError(try session.unlock(pin: "928461"))
        fields["version"] = 999
        let unsupported = try JSONDecoder().decode(PINConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try PINSession(configuration: unsupported, session: saved))
    }

    func testSavedSessionIsBoundToCLIAccountAndServer() {
        let status = BWStatus(status: "locked", userEmail: saved.email, serverUrl: saved.server, lastSync: nil)
        XCTAssertTrue(saved.matches(path: "/test/bw", status: status))
        XCTAssertFalse(saved.matches(path: "/test/bw", status: BWStatus(status: nil, userEmail: saved.email, serverUrl: saved.server, lastSync: nil)))
        XCTAssertFalse(saved.matches(path: "/other/bw", status: status))
        XCTAssertFalse(saved.matches(path: "/test/bw", status: BWStatus(status: "locked", userEmail: "other@example.invalid", serverUrl: saved.server, lastSync: nil)))
        XCTAssertFalse(saved.matches(path: "/test/bw", status: BWStatus(status: "locked", userEmail: saved.email, serverUrl: "https://other.invalid", lastSync: nil)))
        XCTAssertFalse(saved.matches(path: "/test/bw", status: BWStatus(status: "unauthenticated", userEmail: saved.email, serverUrl: saved.server, lastSync: nil)))
    }
}

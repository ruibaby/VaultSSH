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

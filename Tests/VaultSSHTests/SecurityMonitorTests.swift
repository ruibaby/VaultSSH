import XCTest
import AppKit
@testable import VaultSSH

@MainActor
final class SecurityMonitorTests: XCTestCase {
    func testLockSignalsAndWakeNeverUnlock() {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var locks = 0
        let monitor = SecurityMonitor(workspace: workspace, distributed: distributed,
                                      idleTime: { 0 }, lock: { locks += 1 })
        monitor.start()
        monitor.start()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.post(name: name, object: nil)
        }
        distributed.post(name: SecurityMonitor.screenLocked, object: nil)
        XCTAssertEqual(locks, 4)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(locks, 4)
        monitor.stop()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(locks, 4)
    }

    func testIdleLockIsDisabledByDefault() {
        var locks = 0
        let monitor = SecurityMonitor(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                      idleTime: { 100_000 }, lock: { locks += 1 })
        monitor.checkIdle()
        XCTAssertEqual(locks, 0)
    }

    func testIdleThreshold() {
        var idle: TimeInterval = 899
        var locks = 0
        let monitor = SecurityMonitor(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                      idleTime: { idle }, idleLimit: { 900 }, lock: { locks += 1 })
        monitor.checkIdle()
        XCTAssertEqual(locks, 0)
        idle = 900
        monitor.checkIdle()
        XCTAssertEqual(locks, 1)
    }
}

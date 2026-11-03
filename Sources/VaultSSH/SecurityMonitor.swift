import AppKit
import CoreGraphics

@MainActor
final class SecurityMonitor {
    static let idleLimit: TimeInterval = 15 * 60
    // macOS has no public NSWorkspace screen-lock notification. Treat this
    // distributed notification as an additional best-effort lock-only signal.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private let idleTime: () -> TimeInterval
    private let lock: () -> Void

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         idleTime: @escaping () -> TimeInterval = {
             CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                 eventType: CGEventType(rawValue: UInt32.max)!)
         }, lock: @escaping () -> Void) {
        self.workspace = workspace
        self.distributed = distributed
        self.idleTime = idleTime
        self.lock = lock
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        observe(distributed, Self.screenLocked)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        observers.append((center, observer))
    }

    func checkIdle() {
        if idleTime() >= Self.idleLimit { lock() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

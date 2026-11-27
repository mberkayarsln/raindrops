import AppKit

final class SystemStateMonitor {
    static let didChangeNotification = Notification.Name("RaindropsSystemStateDidChange")

    private(set) var isScreenLocked = SystemStateMonitor.currentLockState()
    private(set) var areScreensAsleep = false
    private(set) var isSystemAsleep = false
    private(set) var isSessionActive = true
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []

    var allowsRendering: Bool {
        !isScreenLocked && !areScreensAsleep && !isSystemAsleep && isSessionActive
    }

    init() {
        observeWorkspace()
        observeScreenLock()
        observePowerState()
    }

    deinit {
        observations.forEach { $0.0.removeObserver($0.1) }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.screensDidSleepNotification) { $0.areScreensAsleep = true }
        observe(center, NSWorkspace.screensDidWakeNotification) { $0.areScreensAsleep = false }
        observe(center, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        observe(center, NSWorkspace.didWakeNotification) { $0.isSystemAsleep = false }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionActive = false }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionActive = true }
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        observe(center, Notification.Name("com.apple.screenIsLocked")) { $0.isScreenLocked = true }
        observe(center, Notification.Name("com.apple.screenIsUnlocked")) { $0.isScreenLocked = false }
    }

    private func observePowerState() {
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
            $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, update: @escaping (SystemStateMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            update(self)
            FrameDiagnostics.log("system state \(name.rawValue) rendering=\(self.allowsRendering) lowPower=\(self.isLowPowerModeEnabled)")
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        observations.append((center, token))
    }

    private static func currentLockState() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

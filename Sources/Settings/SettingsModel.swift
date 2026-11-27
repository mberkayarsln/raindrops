import Combine
import Foundation

final class SettingsModel: ObservableObject {
    let settings: AppSettings
    private let launchAtLogin: LaunchAtLoginController
    private let strike: () -> Void
    private var observer: NSObjectProtocol?

    init(settings: AppSettings, launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(), strike: @escaping () -> Void) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.strike = strike
        observer = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }

    var launchesAtLogin: Bool {
        get { launchAtLogin.isEnabled }
        set {
            launchAtLogin.setEnabled(newValue)
            objectWillChange.send()
        }
    }

    var canStrikeLightning: Bool {
        settings.isEnabled && settings.isStormEnabled
    }

    func strikeLightning() {
        strike()
    }
}

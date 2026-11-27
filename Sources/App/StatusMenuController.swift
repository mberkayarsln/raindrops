import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var toggleItem = NSMenuItem()
    private var intensityItems: [RainIntensity: NSMenuItem] = [:]
    private var settingsObserver: NSObjectProtocol?

    init(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
        super.init()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            self?.refreshState()
        }
        refreshState()
    }

    deinit {
        settingsObserver.map(NotificationCenter.default.removeObserver)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        toggleItem = actionItem("Start Rain", action: #selector(toggleEnabled))
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        for intensity in RainIntensity.allCases {
            let item = actionItem(intensity.title, action: #selector(selectIntensity(_:)))
            item.representedObject = intensity.rawValue
            intensityItems[intensity] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = actionItem("Settings…", action: #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        let quitItem = actionItem("Quit Raindrops", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshState() {
        toggleItem.title = settings.isEnabled ? "Stop Rain" : "Start Rain"
        intensityItems.forEach { $0.value.state = $0.key == settings.intensity ? .on : .off }
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let image = NSImage(named: settings.isEnabled ? "RainOn" : "RainOff")
        image?.isTemplate = true
        image?.accessibilityDescription = settings.isEnabled ? "Raindrops, rain on" : "Raindrops, rain off"
        statusItem.button?.image = image
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        refreshState()
    }

    @objc private func selectIntensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let intensity = RainIntensity(rawValue: raw) else { return }
        settings.intensity = intensity
        refreshState()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

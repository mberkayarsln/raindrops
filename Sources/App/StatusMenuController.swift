import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let strikeLightning: () -> Void
    private let launchAtLogin = LaunchAtLoginController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var toggleItem = NSMenuItem()
    private var intensityItems: [RainIntensity: NSMenuItem] = [:]
    private var dropCountItems: [Int: NSMenuItem] = [:]
    private var screenItems: [ScreenSelection: NSMenuItem] = [:]
    private var poolItem = NSMenuItem()
    private var cursorItem = NSMenuItem()
    private var launchItem = NSMenuItem()
    private var soundItem = NSMenuItem()
    private var stormItem = NSMenuItem()
    private var strikeItem = NSMenuItem()
    private var volumeSlider = NSSlider()

    private var windSlider = NSSlider()
    private var poolLevelSlider = NSSlider()
    private var poolLevelLabel = NSTextField(labelWithString: "")
    private var windLabel = NSTextField(labelWithString: "")

    init(settings: AppSettings, strikeLightning: @escaping () -> Void) {
        self.settings = settings
        self.strikeLightning = strikeLightning
        super.init()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        toggleItem = actionItem("Yağmur", action: #selector(toggleEnabled))
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        addIntensitySection()
        menu.addItem(.separator())
        addWindSection()
        addDropCountSection()
        menu.addItem(.separator())
        addPoolSection()
        cursorItem = actionItem("İmleç Etkileşimi", action: #selector(toggleCursor))
        menu.addItem(cursorItem)
        menu.addItem(.separator())
        addSoundSection()
        menu.addItem(.separator())
        addScreenSection()
        menu.addItem(.separator())
        launchItem = actionItem("Girişte Başlat", action: #selector(toggleLaunchAtLogin))
        menu.addItem(launchItem)
        menu.addItem(.separator())
        let quitItem = actionItem("Çıkış", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func addIntensitySection() {
        menu.addItem(headerItem("Yoğunluk"))
        for intensity in RainIntensity.allCases {
            let item = actionItem(intensity.title, action: #selector(selectIntensity(_:)))
            item.representedObject = intensity.rawValue
            intensityItems[intensity] = item
            menu.addItem(item)
        }
    }

    private func addWindSection() {
        windSlider = makeSlider(range: AppSettings.windRange, action: #selector(windChanged(_:)))
        windSlider.numberOfTickMarks = AppSettings.windLevels.count
        windSlider.allowsTickMarkValuesOnly = true
        windSlider.tickMarkPosition = .below
        menu.addItem(sliderItem(title: "Rüzgâr", slider: windSlider, accessory: windLabel))
    }

    private func addDropCountSection() {
        let parent = NSMenuItem(title: "Damla Üst Sınırı", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for count in AppSettings.dropCountOptions {
            let item = actionItem("\(count)", action: #selector(selectDropCount(_:)))
            item.representedObject = count
            dropCountItems[count] = item
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addPoolSection() {
        poolItem = actionItem("Dipte Su Birikmesi", action: #selector(togglePool))
        menu.addItem(poolItem)
        poolLevelSlider = makeSlider(range: AppSettings.poolFractionRange, action: #selector(poolLevelChanged(_:)))
        menu.addItem(sliderItem(title: "Maksimum Seviye", slider: poolLevelSlider, accessory: poolLevelLabel))
    }

    private func addSoundSection() {
        soundItem = actionItem("Yağmur Sesi", action: #selector(toggleSound))
        menu.addItem(soundItem)
        volumeSlider = makeSlider(range: AppSettings.volumeRange, action: #selector(volumeChanged(_:)))
        menu.addItem(sliderItem(title: "Ses Düzeyi", slider: volumeSlider, accessory: nil))
        stormItem = actionItem("Gök Gürültüsü ve Şimşek", action: #selector(toggleStorm))
        stormItem.toolTip = "Yağmur ve Sağanak modunda ara sıra şimşek çakar. Çisentide fırtına olmaz."
        menu.addItem(stormItem)
        strikeItem = actionItem("Şimdi Şimşek Çaktır", action: #selector(strikeNow))
        menu.addItem(strikeItem)
    }

    private func addScreenSection() {
        menu.addItem(headerItem("Ekranlar"))
        for selection in ScreenSelection.allCases {
            let item = actionItem(selection.title, action: #selector(selectScreens(_:)))
            item.representedObject = selection.rawValue
            screenItems[selection] = item
            menu.addItem(item)
        }
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeSlider(range: ClosedRange<Double>, action: Selector) -> NSSlider {
        let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    private func sliderItem(title: String, slider: NSSlider, accessory: NSTextField?) -> NSMenuItem {
        let width = SliderLayout.width
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        container.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: SliderLayout.textLeading, y: 24, width: 150, height: 16)
        let sliderHeight: CGFloat = slider.numberOfTickMarks > 0 ? 24 : 20
        slider.frame = NSRect(x: SliderLayout.sliderLeading, y: 24 - sliderHeight, width: width - SliderLayout.sliderLeading - SliderLayout.trailing, height: sliderHeight)
        slider.autoresizingMask = [.width]
        container.addSubview(label)
        container.addSubview(slider)
        if let accessory {
            accessory.font = .menuFont(ofSize: 0)
            accessory.textColor = .secondaryLabelColor
            accessory.alignment = .right
            accessory.frame = NSRect(x: width - SliderLayout.trailing - 62, y: 24, width: 62, height: 16)
            accessory.autoresizingMask = [.minXMargin]
            container.addSubview(accessory)
        }
        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func refreshState() {
        toggleItem.title = settings.isEnabled ? "Yağmuru Durdur" : "Yağmuru Başlat"
        intensityItems.forEach { $0.value.state = $0.key == settings.intensity ? .on : .off }
        dropCountItems.forEach { $0.value.state = $0.key == settings.maximumDropCount ? .on : .off }
        screenItems.forEach { $0.value.state = $0.key == settings.screenSelection ? .on : .off }
        poolItem.state = settings.isPoolEnabled ? .on : .off
        cursorItem.state = settings.isCursorInteractionEnabled ? .on : .off
        launchItem.state = launchAtLogin.isEnabled ? .on : .off
        soundItem.state = settings.isSoundEnabled ? .on : .off
        volumeSlider.doubleValue = settings.soundVolume
        volumeSlider.isEnabled = settings.isSoundEnabled
        stormItem.state = settings.isStormEnabled ? .on : .off
        strikeItem.isEnabled = settings.isEnabled && settings.isStormEnabled
        windSlider.doubleValue = settings.wind
        updateWindLabel()
        poolLevelSlider.doubleValue = settings.poolMaximumFraction
        poolLevelSlider.isEnabled = settings.isPoolEnabled
        updatePoolLevelLabel()
        updateStatusIcon()
    }

    private func updateWindLabel() {
        windLabel.stringValue = Self.windDescription(for: settings.wind)
    }

    private static func windDescription(for wind: Double) -> String {
        let titles = ["Sakin", "Hafif", "Orta", "Sert", "Fırtına"]
        let index = AppSettings.windLevels.firstIndex(of: AppSettings.nearestWindLevel(to: wind)) ?? 0
        return titles[min(index, titles.count - 1)]
    }

    private func updatePoolLevelLabel() {
        poolLevelLabel.stringValue = "%\(Int((settings.poolMaximumFraction * 100).rounded()))"
    }

    private func updateStatusIcon() {
        let symbol = settings.isEnabled ? "cloud.rain.fill" : "cloud"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Raindrops")
        image?.isTemplate = true
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

    @objc private func selectDropCount(_ sender: NSMenuItem) {
        guard let count = sender.representedObject as? Int else { return }
        settings.maximumDropCount = count
        refreshState()
    }

    @objc private func selectScreens(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let selection = ScreenSelection(rawValue: raw) else { return }
        settings.screenSelection = selection
        refreshState()
    }

    @objc private func windChanged(_ sender: NSSlider) {
        settings.wind = sender.doubleValue
        updateWindLabel()
    }

    @objc private func poolLevelChanged(_ sender: NSSlider) {
        settings.poolMaximumFraction = sender.doubleValue
        updatePoolLevelLabel()
    }

    @objc private func togglePool() {
        settings.isPoolEnabled.toggle()
        refreshState()
    }

    @objc private func toggleCursor() {
        settings.isCursorInteractionEnabled.toggle()
        refreshState()
    }

    @objc private func toggleSound() {
        settings.isSoundEnabled.toggle()
        refreshState()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        settings.soundVolume = sender.doubleValue
    }

    @objc private func toggleStorm() {
        settings.isStormEnabled.toggle()
        refreshState()
    }

    @objc private func strikeNow() {
        strikeLightning()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        refreshState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private enum SliderLayout {
    static let width: CGFloat = 272
    static let textLeading: CGFloat = 28
    static let sliderLeading: CGFloat = 30
    static let trailing: CGFloat = 16
}

import AppKit

final class OverlayManager {
    private let settings: AppSettings
    private let context: MetalContext
    private let systemState = SystemStateMonitor()
    private let geometry = WindowGeometryProvider()
    private var overlays: [ScreenOverlay] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activeScreenSelection: ScreenSelection?
    private let spaceTracker = SpaceTracker()
    private var hostSpaceID: Int?

    init(settings: AppSettings, context: MetalContext) {
        self.settings = settings
        self.context = context
    }

    func start() {
        observeNotifications()
        rebuildOverlays()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        overlays.forEach { $0.tearDown() }
        overlays.removeAll()
        geometry.stop()
    }

    private var configuration: SimulationConfiguration {
        SimulationConfiguration(settings: settings, isLowPowerModeEnabled: systemState.isLowPowerModeEnabled)
    }

    private var shouldRender: Bool {
        settings.isEnabled && systemState.allowsRendering
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppSettings.didChangeNotification, object: settings, queue: .main) { [weak self] _ in
            self?.handleSettingsChange()
        })
        observers.append(center.addObserver(forName: SystemStateMonitor.didChangeNotification, object: systemState, queue: .main) { [weak self] _ in
            self?.applyConfiguration()
            self?.updateRunningState()
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleActiveSpaceChange()
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
        })
    }

    private func handleSettingsChange() {
        if activeScreenSelection != settings.screenSelection {
            rebuildOverlays()
            return
        }
        applyConfiguration()
        updateRunningState()
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.tearDown() }
        activeScreenSelection = settings.screenSelection
        let joinsAllSpaces = settings.screenSelection == .allScreens
        hostSpaceID = nil
        geometry.updateScreenMetrics()
        let current = configuration
        overlays = targetScreens().compactMap { ScreenOverlay(screen: $0, context: context, geometry: geometry, configuration: current, joinsAllSpaces: joinsAllSpaces) }
        FrameDiagnostics.log("rebuilt \(overlays.count) overlays for \(NSScreen.screens.count) screens, configuration=\(current)")
        updateRunningState()
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch settings.screenSelection {
        case .allScreens:
            return screens
        case .primaryOnly:
            guard let state = spaceTracker.primaryDesktopState() else { return Array(screens.prefix(1)) }
            guard state.isOnFirstDesktop else { return [] }
            hostSpaceID = state.firstDesktopID
            return Array(screens.prefix(1))
        }
    }

    private func handleActiveSpaceChange() {
        guard settings.screenSelection == .primaryOnly, let state = spaceTracker.primaryDesktopState() else { return }
        let isHostedOnFirstDesktop = !overlays.isEmpty && hostSpaceID == state.firstDesktopID
        guard state.isOnFirstDesktop, !isHostedOnFirstDesktop else { return }
        FrameDiagnostics.log("placing overlay on first desktop \(state.firstDesktopID)")
        rebuildOverlays()
    }

    private func applyConfiguration() {
        let current = configuration
        overlays.forEach { $0.apply(current) }
    }

    private func updateRunningState() {
        let visible = settings.isEnabled
        let running = shouldRender
        if running {
            geometry.start()
        } else {
            geometry.stop()
        }
        overlays.forEach { $0.setState(visible: visible, running: running) }
    }
}

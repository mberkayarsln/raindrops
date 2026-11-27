import AppKit
import QuartzCore

final class OverlayManager {
    private struct WindDown {
        let start: CFTimeInterval
        let dripTimes: [TimeInterval]
        let fadeStart: TimeInterval
        var nextDrip = 0
        var isFading = false
    }

    private static let taperDuration: TimeInterval = 6
    private static let fadeDuration: TimeInterval = 1.2

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
    private var wasEnabled = true
    private let sound = RainSoundEngine()
    private let storm = StormController()
    private var windDown: WindDown?
    private var windDownTimer: Timer?
    private var random = FastRandom()
    private var windSchedule = WindSchedule.steady(strength: 0)

    init(settings: AppSettings, context: MetalContext) {
        self.settings = settings
        self.context = context
    }

    func start() {
        wasEnabled = settings.isEnabled
        windSchedule = .steady(strength: Float(settings.wind))
        storm.onStrike = { [weak self] strike in
            self?.deliver(strike)
        }
        observeNotifications()
        rebuildOverlays()
    }

    func stop() {
        clearWindDown()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        overlays.forEach { $0.tearDown() }
        overlays.removeAll()
        geometry.stop()
        storm.cancel()
        sound.update(isActive: false, profile: .silent, volume: 0)
    }

    func strikeLightningNow() {
        guard settings.isEnabled, shouldRender else { return }
        storm.strikeNow(distance: 0.15)
    }

    private func deliver(_ strike: LightningStrike) {
        let rendering = overlays.enumerated().filter { $0.element.isRendering }
        guard !rendering.isEmpty else { return }
        let boltIndex = strike.boltScreenIndex.map { $0 % rendering.count }
        for (position, overlay) in rendering.map(\.element).enumerated() {
            overlay.strike(strike, showsBolt: position == boltIndex)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + strike.thunderDelay) { [weak self] in
            self?.sound.thunder(distance: strike.distance)
        }
    }

    private func updateAmbience() {
        let active = shouldRender && overlays.contains { $0.isRendering }
        FrameDiagnostics.log("ambience active=\(active) shouldRender=\(shouldRender) rendering=\(overlays.map(\.isRendering)) sound=\(settings.isSoundEnabled)")
        sound.update(
            isActive: active && settings.isSoundEnabled,
            profile: SoundProfile(intensity: settings.intensity, windSchedule: windSchedule, windDirection: settings.windDirection),
            volume: Float(settings.soundVolume)
        )
        storm.update(isActive: active && settings.isEnabled && settings.isStormEnabled, intensity: settings.intensity, screenCount: overlays.count)
    }

    private var configuration: SimulationConfiguration {
        SimulationConfiguration(settings: settings, isLowPowerModeEnabled: systemState.isLowPowerModeEnabled, windSchedule: windSchedule)
    }

    private var wantsRain: Bool {
        settings.isEnabled || windDown != nil
    }

    private var shouldRender: Bool {
        wantsRain && systemState.allowsRendering
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppSettings.didChangeNotification, object: settings, queue: .main) { [weak self] _ in
            self?.handleSettingsChange()
        })
        observers.append(center.addObserver(forName: SystemStateMonitor.didChangeNotification, object: systemState, queue: .main) { [weak self] _ in
            self?.handleSystemStateChange()
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleActiveSpaceChange()
            DispatchQueue.main.async { self?.updateAmbience() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconcileOverlays()
        })
    }

    private func handleSettingsChange() {
        let turnedOn = settings.isEnabled && !wasEnabled
        let turnedOff = !settings.isEnabled && wasEnabled
        wasEnabled = settings.isEnabled
        windSchedule = windSchedule.retargeted(to: Float(settings.wind), at: CACurrentMediaTime())
        if turnedOn {
            resumeRain()
        }
        if activeScreenSelection != settings.screenSelection {
            clearWindDown()
            rebuildOverlays()
            return
        }
        if turnedOff, systemState.allowsRendering, overlays.contains(where: \.isRendering) {
            beginWindDown()
        }
        applyConfiguration()
        updateRunningState()
    }

    private func handleSystemStateChange() {
        if !systemState.allowsRendering, windDown != nil {
            clearWindDown()
            resetAfterWindDown()
        }
        applyConfiguration()
        updateRunningState()
    }

    private func resumeRain() {
        let wasWindingDown = windDown != nil
        clearWindDown()
        sound.setRainLevel(1)
        overlays.forEach { overlay in
            overlay.setRainLevel(1)
            if wasWindingDown {
                overlay.restoreOpacity(duration: 0.4)
            } else {
                overlay.resetSimulation()
            }
        }
    }

    private func beginWindDown() {
        var dripTimes: [TimeInterval] = []
        var time = Self.taperDuration + TimeInterval(random.value(in: 0.1...0.4))
        for index in 0..<random.integer(in: 3...4) {
            dripTimes.append(time)
            time += TimeInterval(random.value(in: 0.45...0.75)) * (1 + 0.45 * Double(index))
        }
        windDown = WindDown(start: CACurrentMediaTime(), dripTimes: dripTimes, fadeStart: (dripTimes.last ?? Self.taperDuration) + 0.9)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceWindDown()
        }
        RunLoop.main.add(timer, forMode: .common)
        windDownTimer = timer
        FrameDiagnostics.log("rain winding down, drips at \(dripTimes)")
    }

    private func advanceWindDown() {
        guard var state = windDown else { return }
        let elapsed = CACurrentMediaTime() - state.start
        let level = Float(pow(max(1 - elapsed / Self.taperDuration, 0), 1.6))
        overlays.forEach { $0.setRainLevel(level) }
        sound.setRainLevel(level)
        while state.nextDrip < state.dripTimes.count, elapsed >= state.dripTimes[state.nextDrip] {
            sound.drip(strength: 1 - 0.13 * Float(state.nextDrip))
            state.nextDrip += 1
        }
        if !state.isFading, elapsed >= state.fadeStart {
            state.isFading = true
            overlays.forEach { $0.fadeOut(duration: Self.fadeDuration) }
        }
        windDown = state
        guard elapsed >= state.fadeStart + Self.fadeDuration else { return }
        clearWindDown()
        updateRunningState()
        resetAfterWindDown()
    }

    private func clearWindDown() {
        windDownTimer?.invalidate()
        windDownTimer = nil
        windDown = nil
    }

    private func resetAfterWindDown() {
        overlays.forEach { overlay in
            overlay.setRainLevel(1)
            overlay.resetSimulation()
            overlay.restoreOpacity()
        }
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

    private func reconcileOverlays() {
        geometry.updateScreenMetrics()
        let joinsAllSpaces = settings.screenSelection == .allScreens
        let screens = settings.screenSelection == .primaryOnly && overlays.isEmpty ? [] : desiredScreens()
        let unchanged = screens.count == overlays.count && zip(screens, overlays).allSatisfy { screen, overlay in
            screen.displayID == overlay.displayID && screen.frame == overlay.frame
        }
        guard !unchanged else { return }
        let current = configuration
        var kept: [ScreenOverlay] = []
        var reused = Set<CGDirectDisplayID>()
        for screen in screens {
            if let existing = overlays.first(where: { $0.displayID == screen.displayID && $0.frame == screen.frame && $0.joinsAllSpaces == joinsAllSpaces }) {
                kept.append(existing)
                reused.insert(existing.displayID)
            } else if let created = ScreenOverlay(screen: screen, context: context, geometry: geometry, configuration: current, joinsAllSpaces: joinsAllSpaces) {
                kept.append(created)
            }
        }
        overlays.filter { !reused.contains($0.displayID) }.forEach { $0.tearDown() }
        overlays = kept
        FrameDiagnostics.log("reconciled overlays: kept \(reused.count), total \(overlays.count)")
        updateRunningState()
    }

    private func desiredScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch settings.screenSelection {
        case .allScreens: return screens
        case .primaryOnly: return Array(screens.prefix(1))
        }
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
        let visible = wantsRain
        let running = shouldRender
        if running {
            geometry.start()
        } else {
            geometry.stop()
        }
        overlays.forEach { $0.setState(visible: visible, running: running) }
        updateAmbience()
    }
}

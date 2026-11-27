import AppKit
import MetalKit
import QuartzCore

final class ScreenOverlay: NSObject {
    let displayID: CGDirectDisplayID
    private let window: OverlayWindow
    private let metalView: MTKView
    private let renderer: OverlayRenderer
    private let simulation: RainSimulation
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var startTimestamp: CFTimeInterval?
    private var screenFrame: CGRect
    private let screen: NSScreen
    private var maximumFramesPerSecond: Int
    private var isLowPowerModeEnabled = false
    private let diagnostics: FrameDiagnostics
    private let geometry: WindowGeometryProvider
    private var previousCursor: SIMD2<Float>?
    private var cursorVelocity = SIMD2<Float>.zero
    private var isShown = false
    private var isRunningRequested = false
    private var spaceObserver: NSObjectProtocol?
    let joinsAllSpaces: Bool

    init?(screen: NSScreen, context: MetalContext, geometry: WindowGeometryProvider, configuration: SimulationConfiguration, joinsAllSpaces: Bool) {
        guard let displayID = screen.displayID else { return nil }
        let frame = screen.frame
        let simulation = RainSimulation(size: SIMD2(Float(frame.width), Float(frame.height)), configuration: configuration)
        guard let renderer = OverlayRenderer(context: context, simulation: simulation) else { return nil }
        self.displayID = displayID
        self.screenFrame = frame
        self.screen = screen
        self.geometry = geometry
        self.maximumFramesPerSecond = max(60, screen.maximumFramesPerSecond)
        self.simulation = simulation
        self.renderer = renderer
        self.joinsAllSpaces = joinsAllSpaces
        self.window = OverlayWindow(screen: screen, joinsAllSpaces: joinsAllSpaces)
        self.metalView = Self.makeMetalView(size: frame.size, context: context)
        self.diagnostics = FrameDiagnostics(label: "display \(displayID)")
        super.init()
        metalView.delegate = renderer
        window.contentView = metalView
        observeActiveSpace()
    }

    func apply(_ configuration: SimulationConfiguration) {
        simulation.apply(configuration)
        if isLowPowerModeEnabled != configuration.isLowPowerModeEnabled {
            isLowPowerModeEnabled = configuration.isLowPowerModeEnabled
            updateFrameRateRange()
        }
    }

    var frame: CGRect {
        screenFrame
    }

    var isRendering: Bool {
        displayLink.map { !$0.isPaused } ?? false
    }

    func resetSimulation() {
        simulation.reset()
    }

    func strike(_ strike: LightningStrike, showsBolt: Bool) {
        guard isRendering else { return }
        simulation.strike(strike, showsBolt: showsBolt)
    }

    func setState(visible: Bool, running: Bool) {
        if visible && !isShown {
            window.orderFrontRegardless()
        } else if !visible && isShown {
            window.orderOut(nil)
        }
        isShown = visible
        isRunningRequested = visible && running
        updateRunning()
        FrameDiagnostics.log("overlay \(displayID) visible=\(visible) running=\(running) frame=\(window.frame)")
    }

    func tearDown() {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        metalView.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    private func observeActiveSpace() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateRunning()
        }
    }

    private func updateRunning() {
        setRunning(isRunningRequested && window.isOnActiveSpace)
    }

    private func setRunning(_ running: Bool) {
        if running {
            let link = displayLink ?? makeDisplayLink()
            lastTimestamp = nil
            link.isPaused = false
        } else {
            displayLink?.isPaused = true
        }
    }

    private func makeDisplayLink() -> CADisplayLink {
        let link = screen.displayLink(target: self, selector: #selector(handleFrame(_:)))
        displayLink = link
        updateFrameRateRange()
        link.add(to: .main, forMode: .common)
        return link
    }

    private func updateFrameRateRange() {
        let maximum = Float(isLowPowerModeEnabled ? min(60, maximumFramesPerSecond) : maximumFramesPerSecond)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = frameDelta(at: now)
        renderer.elapsedTime = Float(now - (startTimestamp ?? now))
        let start = CACurrentMediaTime()
        simulation.step(dt: dt, time: now, windows: geometry.windows(at: now), screenOrigin: screenOrigin, cursor: sampleCursor(dt: dt))
        metalView.draw()
        let cost = CACurrentMediaTime() - start
        diagnostics.record(at: now, simulationCost: cost) { simulation.diagnosticSummary }
    }

    private func frameDelta(at now: CFTimeInterval) -> Float {
        if startTimestamp == nil { startTimestamp = now }
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return 1.0 / Float(maximumFramesPerSecond) }
        return Float(min(max(now - last, 0), 1.0 / 20.0))
    }

    private func sampleCursor(dt: Float) -> CursorSample? {
        let location = NSEvent.mouseLocation
        guard screenFrame.insetBy(dx: -40, dy: -40).contains(location) else {
            previousCursor = nil
            cursorVelocity = .zero
            return nil
        }
        let position = SIMD2(Float(location.x - screenFrame.minX), Float(location.y - screenFrame.minY))
        if let previous = previousCursor {
            let instantaneous = (position - previous) / max(dt, 0.001)
            cursorVelocity += (instantaneous - cursorVelocity) * 0.5
        }
        previousCursor = position
        return CursorSample(position: position, velocity: cursorVelocity)
    }

    private var screenOrigin: SIMD2<Float> {
        SIMD2(Float(screenFrame.minX), Float(screenFrame.minY))
    }

    private static func makeMetalView(size: CGSize, context: MetalContext) -> MTKView {
        let view = MTKView(frame: NSRect(origin: .zero, size: size), device: context.device)
        view.colorPixelFormat = context.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        view.autoresizingMask = [.width, .height]
        return view
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

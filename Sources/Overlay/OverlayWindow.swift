import AppKit

final class OverlayWindow: NSWindow {
    static var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    }

    init(screen: NSScreen, joinsAllSpaces: Bool) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        configureAppearance()
        configureBehavior(joinsAllSpaces: joinsAllSpaces)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func configureAppearance() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = 1
        animationBehavior = .none
    }

    private func configureBehavior(joinsAllSpaces: Bool) {
        ignoresMouseEvents = true
        level = Self.overlayLevel
        collectionBehavior = joinsAllSpaces
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = false
        isMovable = false
    }
}

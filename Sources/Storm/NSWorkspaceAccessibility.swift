import AppKit

enum NSWorkspaceAccessibility {
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private var overlayManager: OverlayManager?
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let context = MetalContext.shared else {
            presentMetalUnavailableAlert()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--dump-windows") {
            WindowGeometryProvider.dumpCurrentWindows()
            exit(0)
        }
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            let succeeded = SnapshotHarness(request: request, context: context, settings: settings).run()
            exit(succeeded ? 0 : 1)
        }
        let manager = OverlayManager(settings: settings, context: context)
        overlayManager = manager
        statusMenuController = StatusMenuController(settings: settings) { [weak manager] in manager?.strikeLightningNow() }
        manager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayManager?.stop()
    }

    private func presentMetalUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Metal kullanılamıyor"
        alert.informativeText = "Raindrops bu Mac'te Metal cihazı bulamadı."
        alert.runModal()
    }
}

import Foundation
import ServiceManagement

final class LaunchAtLoginController {
    private var service: SMAppService { .mainApp }

    var isEnabled: Bool {
        service.status == .enabled
    }

    var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("Raindrops login item update failed: \(error.localizedDescription)")
        }
        if requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

import Foundation
import ServiceManagement

/// Keeps the SMAppService login-item registration in step with the setting.
/// A background utility that isn't guaranteed to be running silently fails
/// its core job — after a reboot the hotkey is dead until manually launched.
@MainActor
enum LaunchAtLogin {
    static func sync(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin sync failed: \(error.localizedDescription)")
        }
    }
}

import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the UI can toggle launch-at-login.
/// Only works when the app is launched from a proper .app bundle (not `swift run`).
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isSupported: Bool {
        // SMAppService.mainApp requires the app to be launched from a bundle
        // that macOS has registered. Running from `.build/release/` won't qualify.
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func describeStatus() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }
}

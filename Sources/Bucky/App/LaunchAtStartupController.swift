import Foundation
import ServiceManagement

protocol LaunchAtStartupService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtStartupService {}

enum LaunchAtStartupController {
    enum State {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unavailable
        }
    }

    static func setEnabled(
        _ enabled: Bool,
        service: any LaunchAtStartupService = SMAppService.mainApp,
        openLoginItems: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) throws {
        switch service.status {
        case .enabled:
            if !enabled { try service.unregister() }
        case .notRegistered, .notFound:
            // Like Strange, allow registration without an existing macOS record.
            // register() reports actual failures; .notFound alone is not an error.
            if enabled { try service.register() }
        case .requiresApproval:
            openLoginItems()
        @unknown default:
            throw LaunchAtStartupError.unavailable
        }
    }
}

private enum LaunchAtStartupError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Could not update launch at startup."
    }
}

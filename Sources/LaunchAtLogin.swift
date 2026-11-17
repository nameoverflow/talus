import Combine
import ServiceManagement

protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// macOS owns this preference; it must not be copied into the portable TOML config.
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService = SystemLaunchAtLoginService()) {
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = service.status
        if status != current {
            status = current
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        // A pending request is registered already. Re-registering can fail and
        // cannot override a user's decision in System Settings.
        if enabled && needsApproval {
            openSystemSettings()
            return
        }
        guard enabled != isEnabled || (!enabled && needsApproval) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = "无法\(enabled ? "开启" : "关闭")自动启动：\(error.localizedDescription)"
        }
        // Read back even after errors: permission changes may have taken effect.
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

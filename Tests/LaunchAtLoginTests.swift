import Foundation
import ServiceManagement

private final class FakeLoginService: LaunchAtLoginService {
    var status: SMAppService.Status = .notRegistered
    var registeredStatus: SMAppService.Status = .enabled
    var registerError: Error?
    var unregisterError: Error?
    var registrations = 0
    var removals = 0
    var settingsOpens = 0

    func register() throws {
        registrations += 1
        if let registerError { throw registerError }
        status = registeredStatus
    }
    func unregister() throws {
        removals += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
    func openSystemSettings() { settingsOpens += 1 }
}

@main struct LaunchAtLoginTests {
    static func main() {
        let service = FakeLoginService()
        let model = LaunchAtLoginModel(service: service)
        precondition(!model.isEnabled && !model.needsApproval)
        precondition(service.registrations == 0 && service.removals == 0)
        model.setEnabled(false)
        precondition(service.removals == 0)
        model.setEnabled(true)
        precondition(model.isEnabled && service.registrations == 1)
        model.setEnabled(true)
        precondition(service.registrations == 1)
        model.setEnabled(false)
        precondition(!model.isEnabled && service.removals == 1)

        // External changes in System Settings must win over any local preference.
        service.status = .enabled
        model.refresh()
        precondition(model.isEnabled && service.registrations == 1)
        service.status = .requiresApproval
        model.refresh()
        precondition(!model.isEnabled && model.needsApproval)
        model.setEnabled(true)
        precondition(!model.isEnabled && service.settingsOpens == 1)
        precondition(service.registrations == 1, "Do not re-register a pending request")
        model.setEnabled(false)
        precondition(!model.needsApproval && service.removals == 2)

        service.registeredStatus = .requiresApproval
        model.setEnabled(true)
        precondition(model.needsApproval && !model.isEnabled, "Approval is not enabled")
        model.openSystemSettings()
        precondition(service.settingsOpens == 2)
        model.setEnabled(false)

        // Failed operations must retain the actual system state and surface errors.
        let failure = NSError(domain: "TalusLoginTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "test registration denied"])
        service.registerError = failure
        model.setEnabled(true)
        precondition(!model.isEnabled && model.errorMessage?.contains("test registration denied") == true)
        service.registerError = nil
        service.registeredStatus = .enabled
        model.setEnabled(true)
        precondition(model.isEnabled && model.errorMessage == nil)
        service.unregisterError = failure
        model.setEnabled(false)
        precondition(model.isEnabled && model.errorMessage != nil)
        service.unregisterError = nil
        model.setEnabled(false)
        precondition(!model.isEnabled && model.errorMessage == nil)

        service.status = .notFound
        model.refresh()
        precondition(model.status == .notFound && !model.isEnabled)
        // A newly built app can initially be .notFound before its first registration.
        model.setEnabled(true)
        precondition(model.isEnabled)
        service.unregisterError = failure
        model.setEnabled(false)
        precondition(model.errorMessage != nil)
        service.status = .notRegistered
        model.refresh()
        precondition(!model.isEnabled && model.errorMessage == nil, "Clear stale errors after external changes")
        print("Launch-at-login registration, approval, external changes and failure recovery passed")
    }
}

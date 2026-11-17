import Foundation
import ServiceManagement

/// Run only in its own signed test bundle; never registers the live Talus app.
@main struct LaunchAtLoginProbe {
    static func main() throws {
        guard Bundle.main.bundleIdentifier == "local.talus.testing.login" else {
            throw failure("This probe must run from its isolated test app bundle")
        }
        let model = LaunchAtLoginModel()
        guard model.status == .notRegistered || model.status == .notFound else {
            throw failure("Expected a fresh test login item; found \(model.status.rawValue)")
        }
        print("Initial test login item status: \(model.status.rawValue)")
        defer {
            model.setEnabled(false)
            precondition(model.status == .notRegistered, "Failed to remove the test login item")
        }
        model.setEnabled(true)
        guard model.isEnabled else {
            throw failure(model.errorMessage ?? "Login item requires approval (status \(model.status.rawValue))")
        }
        // Reopening settings reads the same registration without writing it again.
        precondition(LaunchAtLoginModel().isEnabled)
        model.setEnabled(false)
        guard model.status == .notRegistered && model.errorMessage == nil else {
            throw failure(model.errorMessage ?? "Test login item was not removed")
        }
        print("Signed app registered, read back enabled, unregistered and read back disabled; test login item removed")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TalusLoginIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

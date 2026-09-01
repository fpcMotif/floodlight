import Foundation
import ServiceManagement
import Testing
@testable import Floodlight

@MainActor
struct LaunchAtLoginControllerTests {
    @Test func failedFirstRegistrationIsRetriedOnNextLaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.registrationFailed
        var loggedErrors: [String] = []
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            logError: { loggedErrors.append($0) }
        )

        controller.enableOnFirstRun()

        #expect(service.registerCallCount == 1)
        #expect(!defaults.bool(forKey: LaunchAtLoginController.configuredKey))
        #expect(loggedErrors.count == 1)

        service.registerError = nil
        controller.enableOnFirstRun()

        #expect(service.registerCallCount == 2)
        #expect(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
        #expect(controller.isEnabled)
    }

    @Test func alreadyEnabledServiceCompletesFirstRunWithoutReregistering() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.enableOnFirstRun()

        #expect(service.registerCallCount == 0)
        #expect(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    @Test func explicitOptOutPreventsAutomaticReregistration() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        try controller.setEnabled(false)
        controller.enableOnFirstRun()

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 0)
        #expect(!controller.isEnabled)
        #expect(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    @Test func deniedServiceReturnsActionableError() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try controller.setEnabled(true)
        }
        #expect(!defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FloodlightLaunchAtLoginTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}

private enum TestError: Error {
    case registrationFailed
}

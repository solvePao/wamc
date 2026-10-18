import XCTest
import ServiceManagement
@testable import AndroidWebcamAppRuntime

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testRegisterUpdatesStateAndPreservesFailureDetails() {
        let defaults = makeDefaults()
        let service = FakeLoginItemService(status: .notRegistered)
        let login = LaunchAtLogin(service: service, defaults: defaults)

        service.registeredStatus = .enabled
        login.register()
        XCTAssertTrue(login.isEnabled)
        XCTAssertNil(login.lastError)
        XCTAssertEqual(service.registerCount, 1)

        service.registerError = TestFailure.rejected
        service.status = .requiresApproval
        service.registeredStatus = .requiresApproval
        login.register()
        XCTAssertTrue(login.requiresApproval)
        XCTAssertEqual(login.lastError, "registration rejected")
    }

    func testDefaultRegistrationRespectsOptOutAndRegistersOtherwise() {
        let defaults = makeDefaults()
        let service = FakeLoginItemService(status: .notRegistered)
        let login = LaunchAtLogin(service: service, defaults: defaults)

        defaults.set(true, forKey: "wamc.launchAtLoginOptOut")
        login.registerByDefaultIfNeeded()
        XCTAssertEqual(service.registerCount, 0)

        defaults.set(false, forKey: "wamc.launchAtLoginOptOut")
        login.registerByDefaultIfNeeded()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(defaults.bool(forKey: "wamc.launchAtLoginInitialized"))
        XCTAssertTrue(login.isEnabled)
    }

    func testUnregisterPersistsOptOutAndRefreshesAfterCompletion() async {
        let defaults = makeDefaults()
        let service = FakeLoginItemService(status: .enabled)
        let login = LaunchAtLogin(service: service, defaults: defaults)
        let completed = expectation(description: "login item removed")
        service.onUnregister = { completed.fulfill() }

        login.setEnabled(false)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(defaults.bool(forKey: "wamc.launchAtLoginOptOut"))
        XCTAssertFalse(login.isEnabled)
        XCTAssertNil(login.lastError)
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "LaunchAtLoginTests-\(UUID().uuidString)")!
        return defaults
    }
}

private enum TestFailure: LocalizedError {
    case rejected
    var errorDescription: String? { "registration rejected" }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: SMAppService.Status
    var registeredStatus: SMAppService.Status = .enabled
    var registerError: Error?
    private(set) var registerCount = 0
    var onUnregister: (() -> Void)?

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = registeredStatus
    }

    func unregister() async throws {
        status = .notRegistered
        onUnregister?()
    }

    func openLoginItemsSettings() {}
}

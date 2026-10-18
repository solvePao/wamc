import XCTest
import ServiceManagement
@testable import AndroidWebcamAppRuntime

@MainActor
final class AdditionalLaunchAtLoginTests: XCTestCase {
    func testSystemAdapterForwardsOperationsAndExposesStatus() async throws {
        var calls: [String] = []
        let service = SystemLoginItemService(registration: ClosureLoginRegistration(readStatus: { .requiresApproval },
            register: { calls.append("register") }, unregister: { calls.append("unregister") }),
            openSettings: { calls.append("settings") })
        XCTAssertEqual(service.status, .requiresApproval)
        try service.register()
        try await service.unregister()
        service.openLoginItemsSettings()
        XCTAssertEqual(calls, ["register", "unregister", "settings"])
        XCTAssertEqual(SystemLoginItemService().status, SMAppService.mainApp.status)
    }

    func testReenablingClearsOptOutAndUnregisterFailureRemainsVisible() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "wamc.launchAtLoginOptOut")
        var status = SMAppService.Status.enabled
        var calls: [String] = []
        let service = SystemLoginItemService(registration: ClosureLoginRegistration(readStatus: { status },
            register: { calls.append("register"); status = .enabled },
            unregister: { throw NSError(domain: "LoginItemTest", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "unregister rejected"]) }),
            openSettings: { calls.append("settings") })
        let login = LaunchAtLogin(service: service, defaults: defaults)
        login.setEnabled(true)
        XCTAssertFalse(defaults.bool(forKey: "wamc.launchAtLoginOptOut"))
        XCTAssertTrue(login.isEnabled)
        login.registerByDefaultIfNeeded()
        XCTAssertEqual(calls, ["register"], "An enabled login item must not be registered twice")
        login.openLoginItemsSettings()
        XCTAssertEqual(calls, ["register", "settings"])
        login.unregister()
        try await waitUntil("Unregister failure reaches published state") { login.lastError != nil }
        XCTAssertEqual(login.lastError, "unregister rejected")
        XCTAssertTrue(login.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "wamc.launchAtLoginOptOut"))
    }
}

@MainActor
struct ClosureLoginRegistration: LoginItemRegistering {
    let readStatus: () -> SMAppService.Status
    let registerAction: () throws -> Void
    let unregisterAction: () async throws -> Void
    init(readStatus: @escaping () -> SMAppService.Status, register: @escaping () throws -> Void,
         unregister: @escaping () async throws -> Void) {
        self.readStatus = readStatus
        self.registerAction = register
        self.unregisterAction = unregister
    }
    var status: SMAppService.Status { readStatus() }
    func register() throws { try registerAction() }
    func unregister() async throws { try await unregisterAction() }
}

import AppKit
import ServiceManagement
import SwiftUI
import XCTest
import AndroidWebcamCore
@testable import AndroidWebcamAppRuntime

@MainActor
final class ViewActionCoverageTests: XCTestCase {
    func testSharedSourceActionAndProgressControlsUseTheSelectedTarget() {
        let preferences = isolatedDefaults()
        let model = AppModel(preferences: preferences, startServices: false,
                             connection: ConnectionController(receiver: FakeStreamTransport()))
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        SourceSelection(model: model, target: target).select()
        XCTAssertTrue(model.isSourceSelected(target))
        model.performSessionAction()
        XCTAssertTrue(model.sessionAction.isProgress)
        XCTAssertGreaterThan(NSHostingView(rootView: SessionControls(model: model)).fittingSize.height, 0)
        XCTAssertGreaterThan(NSHostingView(rootView: AutomationPreferences(model: model)).fittingSize.height, 0)
        model.cancelSession()
        XCTAssertFalse(model.sessionAction.isProgress)
    }

    func testMenuCommandsOpenSetupActivateAndQuitThroughApplicationBoundary() {
        let model = AppModel(preferences: isolatedDefaults(), startServices: false)
        let windows = RecordingMenuWindows()
        let application = RecordingMenuApplication()
        let commands = MenuCommands(model: model, windows: windows, application: application)
        commands.showWindow()
        XCTAssertEqual(windows.identifiers, ["main"])
        XCTAssertEqual(application.policies, [.regular])
        XCTAssertEqual(application.activations, 1)
        model.setup.showSetup = false
        commands.showSetup()
        XCTAssertTrue(model.setup.showSetup)
        XCTAssertEqual(windows.identifiers, ["main", "main"])
        commands.quit()
        XCTAssertEqual(application.terminations, 1)
    }

    func testMenuBindingsAndSubmenusReflectAndChangeTheirModel() {
        let preferences = isolatedDefaults()
        let loginService = MenuLoginService()
        let login = LaunchAtLogin(service: loginService, defaults: preferences)
        let model = AppModel(preferences: preferences, startServices: false, loginItem: login)
        model.startStreamingAutomatically = false
        model.manualAddress = "127.0.0.1:27183"
        model.useManualAddress()
        let phone = DiscoveredDevice(id: "menu-test-phone", instanceName: "Test phone",
                                     model: "Pixel", brand: "Google", sdk: 35, port: 27183, version: 2)
        model.discoveredDevices = [phone]
        let menu = StableMenuContent(model: model, updater: nil, snapshot: MenuSnapshot(model: model))
        XCTAssertFalse(menu.automaticStreaming.wrappedValue)
        menu.automaticStreaming.wrappedValue = true
        XCTAssertTrue(model.startStreamingAutomatically)
        XCTAssertEqual(menu.qualitySelection.wrappedValue, model.qualityMode)
        menu.qualitySelection.wrappedValue = .balanced
        XCTAssertEqual(model.qualityMode, .balanced)
        XCTAssertFalse(menu.loginEnabled.wrappedValue)
        menu.loginEnabled.wrappedValue = true
        XCTAssertEqual(loginService.registrations, 1)
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertGreaterThan(NSHostingView(rootView: menu.cameraItems).fittingSize.height, 0)
        XCTAssertGreaterThan(NSHostingView(rootView: menu.sourceItems).fittingSize.height, 0)
        XCTAssertGreaterThan(NSHostingView(rootView: menu.preferenceItems).fittingSize.height, 0)
    }

    func testDeferredUpdaterMenuRendersInstallationNotice() {
        let driver = MenuUpdateDriver()
        let updater = AppUpdateController(enabled: true, isStreaming: { true }, makeDriver: { driver })
        updater.startOnce()
        XCTAssertEqual(driver.postponeInstallation?({}), true)
        let host = NSHostingView(rootView: UpdateMenuItem(updater: updater))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(updater.installationDeferred)
    }
}

@MainActor
private final class RecordingMenuWindows: MenuWindowOpening {
    var identifiers: [String] = []
    func callAsFunction(id: String) { identifiers.append(id) }
}

@MainActor
private final class RecordingMenuApplication: MenuApplicationDriving {
    var policies: [NSApplication.ActivationPolicy] = []
    var activations = 0
    var terminations = 0
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool { policies.append(policy); return true }
    func activate(ignoringOtherApps flag: Bool) { activations += 1 }
    func terminate(_ sender: Any?) { terminations += 1 }
}

@MainActor
private final class MenuLoginService: LoginItemServicing {
    var status = SMAppService.Status.notRegistered
    var registrations = 0
    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws { status = .notRegistered }
    func openLoginItemsSettings() {}
}

@MainActor
private final class MenuUpdateDriver: AppUpdateDriving {
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?
    func start() throws {}
    func checkInBackground() {}
    func checkManually() {}
}

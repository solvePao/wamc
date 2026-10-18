import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class SetupViewActionCoverageTests: XCTestCase {
    func testSetupActionsUseInjectedServicesAndRenderWithAndWithoutPlatformTools() async {
        let preferences = isolatedDefaults()
        let environment = ViewActionEnvironment()
        let extensionService = ViewActionExtensionService()
        let manager = CameraExtensionManager()
        manager.status = .active
        let setup = SetupModel(preferences: preferences, environment: environment,
                               packageInspector: ViewActionPackageInspector(), extensionManager: manager,
                               extensionService: extensionService,
                               bundleURL: URL(fileURLWithPath: "/Applications/WAMC.app"))
        let loginService = ViewActionLoginService()
        let probe = ViewActionHealthProbe()
        let monitor = VirtualCameraHealthMonitor(probe: probe)
        monitor.update(feedLive: false, bridgeAvailable: false, extensionEnabled: false)
        let model = AppModel(preferences: preferences, startServices: false,
                             deviceInventory: ViewActionDeviceInventory(), setupModel: setup,
                             loginItem: LaunchAtLogin(service: loginService, defaults: preferences),
                             cameraHealthMonitor: monitor)
        model.startStreamingAutomatically = false
        let view = SetupView(model: model, platformToolsAvailable: false)
        view.openLocalNetworkSettings()
        XCTAssertEqual(environment.openedPanes, ["Privacy_LocalNetwork"])
        view.enableRecommendedDefaults()
        XCTAssertTrue(model.startStreamingAutomatically)
        XCTAssertEqual(loginService.registrations, 1)
        XCTAssertTrue(environment.openedPanes.contains("Privacy_Camera"))
        XCTAssertEqual(extensionService.activations, 1)
        let checks = probe.updates
        view.checkAgain()
        XCTAssertGreaterThan(probe.updates, checks)
        view.applicationBecameActive(Notification(name: NSApplication.didBecomeActiveNotification))
        setup.showSetup = true
        view.dismissSetup()
        XCTAssertFalse(setup.showSetup)
        for toolsAvailable in [false, true] {
            let host = NSHostingView(rootView: SetupView(model: model, platformToolsAvailable: toolsAvailable))
            XCTAssertEqual(host.fittingSize.width, 600)
            XCTAssertEqual(host.fittingSize.height, 640)
        }
        await drainMainQueue()
    }

    func testSystemInventoryQueriesAndMissingDeviceConfigurationAreSafe() {
        let inventory = SystemDeviceInventory()
        let devices = inventory.listAndroidDevices()
        XCTAssertTrue(devices.allSatisfy { !$0.id.isEmpty })
        XCTAssertTrue(inventory.nativeUVCWebcams().allSatisfy { !$0.isEmpty })
        let missingSerial = "wamc-test-\(UUID().uuidString)"
        XCTAssertFalse(devices.contains { $0.id == missingSerial })
        XCTAssertFalse(inventory.configureDefaultUsbMode(serial: missingSerial))
    }
}

@MainActor
private final class ViewActionEnvironment: SetupEnvironment {
    var openedPanes: [String] = []
    func cameraAuthorization() -> AVAuthorizationStatus { .denied }
    func requestCameraAccess(completion: @escaping (Bool) -> Void) { completion(false) }
    func sinkIsRegistered() -> Bool { true }
    func openPrivacyPane(_ pane: String) { openedPanes.append(pane) }
    func terminateApplication() { XCTFail("Setup actions must not terminate the test host") }
}

private struct ViewActionPackageInspector: SetupPackageInspecting {
    func isInstalled(bundleURL: URL) -> Bool { true }
    func signingIssue(bundleURL: URL) -> String? { nil }
}

@MainActor
private final class ViewActionExtensionService: CameraExtensionServicing {
    let status = CameraExtensionManager.Status.active
    var statusPublisher: AnyPublisher<CameraExtensionManager.Status, Never> { Just(status).eraseToAnyPublisher() }
    var activations = 0
    func activate() { activations += 1 }
    func refreshStatus() {}
    func openSystemSettings() {}
}

@MainActor
private final class ViewActionLoginService: LoginItemServicing {
    var status = SMAppService.Status.notRegistered
    var registrations = 0
    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws { status = .notRegistered }
    func openLoginItemsSettings() {}
}

private final class ViewActionHealthProbe: VirtualCameraProbing {
    var onChange: ((UInt64, VirtualCameraHealth) -> Void)?
    var updates = 0
    func update(_ input: VirtualCameraProbe.Input, revision: UInt64) { updates += 1 }
}

private struct ViewActionDeviceInventory: DeviceInventory {
    func listAndroidDevices() -> [AndroidDevice] { [] }
    func nativeUVCWebcams() -> [String] { [] }
    func configureDefaultUsbMode(serial: String?) -> Bool { false }
}

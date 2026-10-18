import AVFoundation
import Combine
import Foundation
import Network
import ServiceManagement
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class AppServiceCoverageTests: XCTestCase {
    func testLiveServiceStartupUsesInjectedServicesAndManualTimerTicks() async throws {
        let preferences = isolatedDefaults()
        preferences.set(false, forKey: "wamc.startStreamingAutomatically")
        let loginService = SystemLoginItemService(registration: ClosureLoginRegistration(readStatus: { .requiresApproval }, register: {},
                                                  unregister: {}), openSettings: {})
        let login = LaunchAtLogin(service: loginService, defaults: preferences)
        let discovery = WifiDiscovery(startBrowser: { _, _ in })
        let timers = ManualAppTimerScheduler()
        let inventory = ServiceTestInventory()
        let setup = SetupModel(preferences: preferences, environment: ServiceTestSetupEnvironment(),
                               packageInspector: ServiceTestPackageInspector())
        let model = AppModel(preferences: preferences, startServices: true,
                             deviceInventory: inventory, setupModel: setup, loginItem: login,
                             discovery: discovery, timerScheduler: timers)
        defer {
            timers.timers.forEach { $0.invalidate() }
            setup.stop()
            discovery.stop()
        }
        try await waitUntil("initial inventory reaches model") { model.nativeWebcams == ["Test camera"] }
        XCTAssertEqual(timers.timers.count, 2)
        XCTAssertTrue(model.launchAtLoginRequiresApproval)
        timers.timers.forEach { $0.fire() }
        await drainMainQueue()
        model.checkCameraOutput()
        model.setLaunchAtLogin(true)
        XCTAssertTrue(model.launchAtLoginRequiresApproval)
    }

    func testKeyframeRecoveryAndTimeoutUseInjectedClockInsteadOfSleeping() async throws {
        let preferences = isolatedDefaults()
        preferences.set(false, forKey: "wamc.startStreamingAutomatically")
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let timers = ManualAppTimerScheduler()
        let discovery = WifiDiscovery(startBrowser: { _, _ in })
        let setup = SetupModel(preferences: preferences, environment: ServiceTestSetupEnvironment(),
                               packageInspector: ServiceTestPackageInspector())
        var now = Date(timeIntervalSince1970: 100)
        let model = AppModel(preferences: preferences, startServices: true, connection: connection,
                             deviceInventory: ServiceTestInventory(), setupModel: setup,
                             loginItem: LaunchAtLogin(service: SystemLoginItemService(registration: ClosureLoginRegistration(
                                readStatus: { .enabled }, register: {}, unregister: {}), openSettings: {}),
                                defaults: preferences), discovery: discovery, timerScheduler: timers,
                             now: { now })
        defer {
            timers.timers.forEach { $0.invalidate() }
            setup.stop()
            discovery.stop()
            connection.disconnect()
        }
        connection.connect(to: .address("127.0.0.1", 27183), manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Clock phone"]), attempt: attempt)
        try await waitUntil("phone connects") { model.connected }
        model.sendStart()
        let displayTimer = try XCTUnwrap(timers.timers.first)
        displayTimer.fire()
        await drainMainQueue()
        now.addTimeInterval(1)
        displayTimer.fire()
        try await waitUntil("second recovery request updates status") {
            model.statusText.contains("requesting recovery")
        }
        XCTAssertGreaterThanOrEqual(transport.sentControls.filter { $0.first?.1 == "requestKeyframe" }.count, 2)
        now.addTimeInterval(12)
        displayTimer.fire()
        try await waitUntil("missing keyframe stalls feed") { model.feedState == .stalled }
        XCTAssertTrue(model.statusText.contains("Keyframe timeout"))
    }

    func testRunLoopTimerAdapterCanBeFiredAndInvalidated() async {
        let called = expectation(description: "scheduled action executes")
        let timer = AppTimerScheduler().repeating(every: 60) { _ in called.fulfill() }
        defer { timer.invalidate() }
        timer.fire()
        XCTAssertTrue(timer.isValid)
        await fulfillment(of: [called], timeout: 1)
    }
}

private final class ManualAppTimerScheduler: AppTimerScheduling {
    private(set) var timers: [Timer] = []
    func repeating(every interval: TimeInterval, action: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true, block: action)
        timers.append(timer)
        return timer
    }
}

private struct ServiceTestInventory: DeviceInventory {
    func listAndroidDevices() -> [AndroidDevice] { [] }
    func nativeUVCWebcams() -> [String] { ["Test camera"] }
    func configureDefaultUsbMode(serial: String?) -> Bool { true }
}

@MainActor
private struct ServiceTestSetupEnvironment: SetupEnvironment {
    func cameraAuthorization() -> AVAuthorizationStatus { .denied }
    func requestCameraAccess(completion: @escaping (Bool) -> Void) { completion(false) }
    func sinkIsRegistered() -> Bool { false }
    func openPrivacyPane(_ pane: String) {}
    func terminateApplication() {}
}

private struct ServiceTestPackageInspector: SetupPackageInspecting {
    func isInstalled(bundleURL: URL) -> Bool { false }
    func signingIssue(bundleURL: URL) -> String? { nil }
}

import XCTest
import SwiftUI
import AppKit
import Network
import AVFoundation
import AndroidWebcamCore
@testable import AndroidWebcamAppRuntime

@MainActor
final class ViewConstructionTests: XCTestCase {
    func testMainWindowViewsBuildFromAnIdleModel() {
        let model = AppModel(startServices: false)

        _ = ContentView(model: model).body
        let preview = NSHostingView(rootView: PreviewPane(model: model))
        _ = preview.fittingSize
        _ = SessionControls(model: model).body
        _ = ConnectionControls(model: model).body
        _ = AutomationPreferences(model: model).body
        _ = CameraControls(connected: false, facingBack: false, quality: .best,
                           setQuality: { _ in }, switchCamera: {}, rotate: {}).body
    }

    func testApplicationSceneBuildsWithoutStartingExternalServices() {
        _ = WAMCApplication(startServices: false).body
    }

    func testSetupAndMenuViewsBuildWhileServicesAreIdle() {
        let model = AppModel(startServices: false)

        _ = SetupView(model: model).body
        _ = MenuContent(model: model).body
    }

    func testMenuSnapshotCapturesWifiAndManualSourcesAndStableBodyBuilds() {
        let model = AppModel(startServices: false)
        let phone = DiscoveredDevice(id: "view-phone", instanceName: "Pixel",
                                     model: "Pixel", brand: "Google", sdk: 35,
                                     port: 27183, version: 2)
        model.discoveredDevices = [phone]
        model.selectSource(.wifi(phone))
        model.manualAddress = "192.168.1.40:27183"
        model.useManualAddress()

        let snapshot = MenuSnapshot(model: model)
        XCTAssertEqual(snapshot.phones.count, 1)
        XCTAssertEqual(snapshot.phones.first?.source.target, .wifi(phone))
        XCTAssertEqual(snapshot.manualSources.map(\.target), [.address("192.168.1.40", 27183)])
        XCTAssertEqual(snapshot.usb.target, .usb(serial: nil))

        let stable = StableMenuContent(model: model, updater: nil, snapshot: snapshot)
        XCTAssertTrue(stable == StableMenuContent(model: model, updater: nil, snapshot: snapshot))
        _ = stable.body
        XCTAssertFalse(stable == StableMenuContent(model: AppModel(startServices: false), updater: nil,
                                                    snapshot: snapshot))
    }

    func testDisconnectedPreviewBuildsGuidanceForStreamingStates() {
        for feedState in [FeedState.idle, .starting, .updating, .stalled] {
            let disconnected = NSHostingView(rootView: DisconnectedPreview(connected: false,
                                                                            feedState: feedState))
            let connected = NSHostingView(rootView: DisconnectedPreview(connected: true,
                                                                         feedState: feedState))
            XCTAssertGreaterThan(disconnected.fittingSize.height, 0)
            XCTAssertGreaterThan(connected.fittingSize.height, 0)
        }
    }

    func testPreviewShowsIdentityMismatchState() async throws {
        let phone = DiscoveredDevice(id: "expected-phone", instanceName: "Pixel",
                                     model: "Pixel", brand: "Google", sdk: 35,
                                     port: 27183, version: 2)
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection)
        connection.connect(to: .wifi(phone),
                           endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 27183)!),
                           manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        let disconnected = expectation(description: "identity mismatch disconnects")
        connection.onStateChange = { state, _ in
            if state == .disconnected { disconnected.fulfill() }
        }

        transport.emit(.hello(["model": "Pixel", "id": "different-phone"]), attempt: attempt)
        await fulfillment(of: [disconnected], timeout: 1)

        let host = NSHostingView(rootView: PreviewPane(model: model))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testSetupViewBuildsEachDeliveryReadinessState() {
        let states: [(Bool, String?, CameraExtensionManager.Status, Bool)] = [
            (false, nil, .notInstalled, false),
            (true, "invalid signature", .notInstalled, false),
            (true, nil, .notInstalled, false),
            (true, nil, .active, false),
            (true, nil, .active, true),
        ]

        for (installed, issue, extensionStatus, sinkRegistered) in states {
            let manager = CameraExtensionManager()
            manager.status = extensionStatus
            let setup = SetupModel(environment: ViewSetupEnvironment(sinkRegistered: sinkRegistered),
                                   packageInspector: ViewSetupPackageInspector(installed: installed,
                                                                              issue: issue),
                                   extensionManager: manager,
                                   bundleURL: URL(fileURLWithPath: "/Applications/WAMC.app"))
            setup.refresh()
            let model = AppModel(startServices: false, setupModel: setup)
            let host = NSHostingView(rootView: SetupView(model: model))

            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testGlassSurfacesAndDisclosureStyleBuildInTheNativeViewTree() {
        let controls = VStack {
            Text("glass surface").wamcGlassSurface(interactive: true)
            Button("Prominent", action: {}).wamcActionStyle(prominent: true)
            Button("Standard", action: {}).wamcActionStyle()
            DisclosureGroup("Diagnostics") { Text("Details") }
                .disclosureGroupStyle(FullRowDisclosureStyle())
        }
        let host = NSHostingView(rootView: GlassControlGroup { controls })

        _ = host.fittingSize
    }
}

@MainActor
private final class ViewSetupEnvironment: SetupEnvironment {
    private let registered: Bool
    init(sinkRegistered: Bool) { registered = sinkRegistered }
    func cameraAuthorization() -> AVAuthorizationStatus { .authorized }
    func requestCameraAccess(completion: @escaping (Bool) -> Void) { completion(true) }
    func sinkIsRegistered() -> Bool { registered }
    func openPrivacyPane(_ pane: String) {}
    func terminateApplication() {}
}

private struct ViewSetupPackageInspector: SetupPackageInspecting {
    let installed: Bool
    let issue: String?
    func isInstalled(bundleURL: URL) -> Bool { installed }
    func signingIssue(bundleURL: URL) -> String? { issue }
}

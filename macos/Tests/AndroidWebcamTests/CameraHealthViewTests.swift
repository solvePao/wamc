import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class CameraHealthViewTests: XCTestCase {
    func testHealthViewsRenderEveryOutputAndPermissionState() async throws {
        for authorization in [AVAuthorizationStatus.authorized, .notDetermined] {
            let probe = ViewHealthProbe()
            let monitor = VirtualCameraHealthMonitor(probe: probe)
            let defaults = isolatedDefaults()
            let environment = SystemSetupEnvironment(readAuthorization: { _ in authorization },
                requestAccess: { _, completion in completion(true) }, readSinkRegistration: { false },
                openURL: { _ in true }, terminate: { _ in })
            let setup = SetupModel(preferences: defaults, environment: environment)
            let model = AppModel(preferences: defaults, startServices: false, setupModel: setup,
                                 cameraHealthMonitor: monitor)
            monitor.update(feedLive: true, bridgeAvailable: true, extensionEnabled: true)
            for output in [VirtualCameraHealth.Output.waiting, .checking, .ready, .failed, .unavailable] {
                let state = VirtualCameraHealth(output: output, detail: "Camera evidence: \(output.rawValue)",
                                                inUse: output == .ready)
                probe.onChange?(1, state)
                try await waitUntil("Health state is published before rendering") { monitor.health == state }
                let host = NSHostingView(rootView: CameraHealthView(model: model))
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
            setup.stop()
        }
    }

    func testHealthActionsRetryPermissionAndRevealDiagnostics() {
        let defaults = isolatedDefaults()
        var requests = 0
        let environment = SystemSetupEnvironment(readAuthorization: { _ in .notDetermined },
            requestAccess: { _, completion in requests += 1; completion(true) }, readSinkRegistration: { false },
            openURL: { _ in true }, terminate: { _ in })
        let setup = SetupModel(preferences: defaults, environment: environment)
        let probe = ViewHealthProbe()
        let monitor = VirtualCameraHealthMonitor(probe: probe)
        let model = AppModel(preferences: defaults, startServices: false, setupModel: setup,
                             cameraHealthMonitor: monitor)
        let view = CameraHealthView(model: model)
        view.showDiagnostics()
        XCTAssertTrue(setup.showSetup)
        view.allowCameraAccess()
        XCTAssertEqual(requests, 1)
        view.checkAgain()
        // The action remains safe when services have not yet started.
        XCTAssertEqual(monitor.health.output, .waiting)
        setup.stop()
    }
}

private final class ViewHealthProbe: VirtualCameraProbing {
    var onChange: ((UInt64, VirtualCameraHealth) -> Void)?
    func update(_ input: VirtualCameraProbe.Input, revision: UInt64) {}
}

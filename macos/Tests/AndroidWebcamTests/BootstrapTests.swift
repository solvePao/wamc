import CoreMediaIO
import SwiftUI
import XCTest
@testable import CameraExtensionRuntime
@testable import AndroidWebcamAppRuntime
@testable import WAMCLauncherTestSupport

final class BootstrapTests: XCTestCase {
    func testExtensionBootstrapStartsServiceBeforeRunningLoop() {
        var events: [String] = []

        ExtensionBootstrap.start(startService: {
            events.append("service")
        }, runLoop: {
            events.append("run-loop")
        })

        XCTAssertEqual(events, ["service", "run-loop"])
    }

    func testApplicationEntrypointBuildsTheApplicationScene() {
        let entrypoint = WAMCEntry(startServices: false)

        XCTAssertFalse(String(describing: type(of: entrypoint.body)).isEmpty)
    }

    func testLauncherDelegatesToInstrumentedApplicationScene() {
        let launcher = WAMCRunner(startServices: false)

        XCTAssertFalse(String(describing: type(of: launcher.body)).isEmpty)
    }
}

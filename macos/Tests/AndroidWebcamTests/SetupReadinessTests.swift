import XCTest
@testable import AndroidWebcamCore

final class SetupReadinessTests: XCTestCase {
    func testApplicationsPrefixMustBeDirectory() {
        XCTAssertTrue(SetupReadiness.isApplicationsInstall("/Applications/WAMC.app"))
        XCTAssertFalse(SetupReadiness.isApplicationsInstall("/Applications-other/WAMC.app"))
        XCTAssertFalse(SetupReadiness.isApplicationsInstall("/Volumes/WAMC/WAMC.app"))
    }

    func testRegistrationDoesNotProveDelivery() {
        XCTAssertEqual(SetupReadiness.evaluate(installed: true, validPackage: true,
            extensionEnabled: true, sinkRegistered: false, sendingFrames: true), .waitingForSink)
        XCTAssertEqual(SetupReadiness.evaluate(installed: true, validPackage: true,
            extensionEnabled: true, sinkRegistered: true, sendingFrames: false), .waitingForPhone)
    }

    func testStaleFeedCannotHideDisabledExtensionOrInvalidPackage() {
        XCTAssertEqual(SetupReadiness.evaluate(installed: true, validPackage: true,
            extensionEnabled: false, sinkRegistered: true, sendingFrames: true), .needsExtension)
        XCTAssertEqual(SetupReadiness.evaluate(installed: true, validPackage: false,
            extensionEnabled: true, sinkRegistered: true, sendingFrames: true), .invalidPackage)
    }

    func testDiskImageMustBeInstalledBeforeActivation() {
        XCTAssertEqual(SetupReadiness.evaluate(installed: false, validPackage: true,
            extensionEnabled: true, sinkRegistered: true, sendingFrames: true), .needsInstallation)
    }

    func testAllDeliveryRequirements() {
        XCTAssertEqual(SetupReadiness.evaluate(installed: true, validPackage: true,
            extensionEnabled: true, sinkRegistered: true, sendingFrames: true), .streaming)
    }
}

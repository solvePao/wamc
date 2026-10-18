import Combine
import SwiftUI
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testLaunchCheckRunsOnceAndManualCheckReusesDriver() {
        let driver = FakeUpdateDriver()
        var constructions = 0
        let updater = AppUpdateController(enabled: true, isStreaming: { false }, makeDriver: {
            constructions += 1
            return driver
        })

        updater.startOnce()
        updater.startOnce()
        updater.checkForUpdates()

        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.backgroundChecks, 1)
        XCTAssertEqual(driver.manualChecks, 1)
    }

    func testDisabledServicesNeverConstructUpdater() {
        var constructions = 0
        let updater = AppUpdateController(enabled: false, isStreaming: { false }, makeDriver: {
            constructions += 1
            return FakeUpdateDriver()
        })

        updater.startOnce()
        updater.checkForUpdates()
        XCTAssertEqual(constructions, 0)
    }

    func testInstallationWaitsUntilStreamIsIdleAndResumesOnlyOnce() {
        let driver = FakeUpdateDriver()
        var streaming = true
        let updater = AppUpdateController(enabled: true, isStreaming: { streaming }, makeDriver: { driver })
        updater.startOnce()
        var installed = 0

        XCTAssertEqual(driver.postponeInstallation?({ installed += 1 }), true)
        XCTAssertTrue(updater.installationDeferred)
        updater.resumeInstallationIfIdle()
        XCTAssertEqual(installed, 0)
        streaming = false
        updater.resumeInstallationIfIdle()
        updater.resumeInstallationIfIdle()
        XCTAssertFalse(updater.installationDeferred)
        XCTAssertEqual(installed, 1)
    }

    func testIdleStreamDoesNotPostponeInstallation() {
        let driver = FakeUpdateDriver()
        let updater = AppUpdateController(enabled: true, isStreaming: { false }, makeDriver: { driver })
        updater.startOnce()

        XCTAssertEqual(driver.postponeInstallation?({ XCTFail("Sparkle owns immediate installation") }), false)
        XCTAssertFalse(updater.installationDeferred)
        updater.resumeInstallationIfIdle()
    }

    func testBackgroundStartupFailureIsSilentAndManualCheckCanRetry() {
        let driver = FakeUpdateDriver()
        driver.startError = NSError(domain: "test", code: 1)
        var errors = 0
        let updater = AppUpdateController(enabled: true, isStreaming: { false },
            makeDriver: { driver }, reportError: { _ in errors += 1 })

        updater.startOnce()
        updater.startOnce()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(errors, 0)
        updater.checkForUpdates()
        XCTAssertEqual(errors, 1)
        driver.startError = nil
        updater.checkForUpdates()
        XCTAssertEqual(driver.starts, 3)
        XCTAssertEqual(driver.manualChecks, 1)
    }

    func testUnbundledAppReportsConfigurationErrorWithoutStartingSparkle() {
        var failure: NSError?
        let updater = AppUpdateController(enabled: true, isStreaming: { false },
            reportError: { failure = $0 as NSError })

        updater.checkForUpdates()

        XCTAssertEqual(failure?.domain, "WAMC.Update")
        XCTAssertEqual(failure?.code, 1)
    }

    func testMenuIncludesUpdaterWhileServicesRemainDisabled() {
        let model = AppModel(startServices: false)
        let updater = AppUpdateController(enabled: false, isStreaming: { false })
        let menu = NSHostingView(rootView: MenuContent(model: model, updater: updater))

        XCTAssertGreaterThan(menu.fittingSize.height, 0)
    }

    func testStatePublisherResumesAfterStateChanges() async {
        let driver = FakeUpdateDriver()
        let changes = PassthroughSubject<Void, Never>()
        var streaming = true
        let updater = AppUpdateController(enabled: true, isStreaming: { streaming },
            changes: changes.eraseToAnyPublisher(), makeDriver: { driver })
        updater.startOnce()
        let resumed = expectation(description: "Install resumes after object state changes")
        XCTAssertEqual(driver.postponeInstallation?({ resumed.fulfill() }), true)

        changes.send()
        streaming = false
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertFalse(updater.installationDeferred)
    }
}

@MainActor
private final class FakeUpdateDriver: AppUpdateDriving {
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?
    var starts = 0
    var backgroundChecks = 0
    var manualChecks = 0
    var startError: Error?

    func start() throws {
        starts += 1
        if let startError { throw startError }
    }
    func checkInBackground() { backgroundChecks += 1 }
    func checkManually() { manualChecks += 1 }
}

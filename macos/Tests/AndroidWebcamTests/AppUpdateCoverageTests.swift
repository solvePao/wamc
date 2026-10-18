import AppKit
import Sparkle
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class AppUpdateCoverageTests: XCTestCase {
    func testSparkleAdapterDisablesAutomaticActionsAndRoutesChecksAndDeferral() throws {
        let bundle = try configuredBundle()
        let native = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = RecordingSparkleUpdater(hostBundle: bundle, applicationBundle: bundle,
                                              userDriver: native.userDriver, delegate: nil)
        let controller = RecordingSparkleController(updater: updater)
        let driver = SparkleUpdateDriver(bundle: bundle, controllerFactory: { _ in controller })

        try driver.start()
        driver.checkInBackground()
        driver.checkManually()

        XCTAssertEqual(updater.starts, 1)
        XCTAssertEqual(updater.backgroundChecks, 1)
        XCTAssertEqual(controller.manualChecks, 1)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertFalse(driver.updaterShouldPromptForPermissionToCheck(forUpdates: updater))
        // Sparkle's public appcast fixture initializer is deprecated, but it is
        // the public way to create the delegate argument without downloading a feed.
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "enclosure": ["url": "https://example.invalid/WAMC.zip", "sparkle:version": "2"],
        ]))
        var installed = false
        XCTAssertFalse(driver.updater(updater, shouldPostponeRelaunchForUpdate: item,
                                      untilInvokingBlock: { installed = true }))
        driver.postponeInstallation = { install in install(); return true }
        XCTAssertTrue(driver.updater(updater, shouldPostponeRelaunchForUpdate: item,
                                     untilInvokingBlock: { installed = true }))
        XCTAssertTrue(installed)
    }

    func testNativeUnconfiguredUpdaterCannotStartOrBeginAnUpdateSession() {
        let driver = SparkleUpdateDriver()
        XCTAssertThrowsError(try driver.start()) { error in
            XCTAssertEqual((error as NSError).domain, "WAMC.Update")
        }
        // Sparkle explicitly refuses these calls before start; this exercises
        // the actual native adapter without contacting an update server.
        driver.checkInBackground()
        driver.checkManually()
    }

    func testDefaultManualErrorPresentationDisplaysAndDismissesTheConfigurationError() {
        _ = NSApplication.shared
        let controller = AppUpdateController(enabled: true, isStreaming: { false })
        var displayed = false
        DispatchQueue.main.async {
            displayed = NSApp.modalWindow != nil
            NSApp.abortModal()
            NSApp.modalWindow?.orderOut(nil)
        }
        controller.checkForUpdates()
        XCTAssertTrue(displayed)
        XCTAssertFalse(controller.installationDeferred)
    }

    private func configuredBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("WAMC.app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let identifier = "com.wamc.tests.\(UUID().uuidString)"
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleVersion": "1",
                                  "CFBundlePackageType": "APPL", "SUPublicEDKey": "test-key"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock {
            UserDefaults(suiteName: identifier)?.removePersistentDomain(forName: identifier)
            try FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        return try XCTUnwrap(Bundle(url: root))
    }
}

@MainActor
private final class RecordingSparkleUpdater: SPUUpdater {
    var starts = 0
    var backgroundChecks = 0
    override func start() throws { starts += 1 }
    override func checkForUpdatesInBackground() { backgroundChecks += 1 }
}

@MainActor
private final class RecordingSparkleController: SPUStandardUpdaterController {
    private let recordedUpdater: SPUUpdater
    var manualChecks = 0
    override var updater: SPUUpdater { recordedUpdater }
    init(updater: SPUUpdater) {
        recordedUpdater = updater
        super.init(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }
    override func checkForUpdates(_ sender: Any?) { manualChecks += 1 }
}

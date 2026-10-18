import AppKit
import XCTest
@testable import AndroidWebcamAppRuntime
@testable import WAMCLauncherTestSupport

@MainActor
final class ApplicationLifecycleCoverageTests: XCTestCase {
    func testFirstLaunchActivatesSetupWithoutSchedulingWindowClosure() {
        let application = NSApplication.shared
        let oldPolicy = application.activationPolicy()
        defer { application.setActivationPolicy(oldPolicy) }
        var enqueued = false
        let delegate = AppDelegate(application: application, needsSetup: { true },
                                   enqueue: { _ in enqueued = true })

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(application.activationPolicy(), .regular)
        XCTAssertFalse(enqueued)
    }

    func testAgentLaunchClosesOnlyItsProcessWindowsAfterLaunch() throws {
        let application = NSApplication.shared
        let oldPolicy = application.activationPolicy()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); application.setActivationPolicy(oldPolicy) }
        window.orderFront(nil)
        var action: (() -> Void)?
        let delegate = AppDelegate(application: application, needsSetup: { false }, enqueue: { action = $0 })

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(application.activationPolicy(), .accessory)
        XCTAssertTrue(window.isVisible)
        try XCTUnwrap(action)()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(application.activationPolicy(), .accessory)
    }

    func testReopenShowsWindowOnlyWhenNoWindowIsVisible() {
        let application = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let delegate = AppDelegate(application: application, needsSetup: { false })

        XCTAssertTrue(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
    }

    func testDefaultDelegateCanBeConstructedForApplicationAdaptor() async {
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        defer { application.setActivationPolicy(policy) }
        let needsSetup = SetupModel.needsFirstRunSetup
        AppDelegate().applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await drainMainQueue()
        XCTAssertEqual(application.activationPolicy(), needsSetup ? .regular : .accessory)
        _ = WAMCEntry()
        _ = WAMCRunner()
    }

    func testDefaultMainQueueSchedulerClosesAgentWindowAfterLaunchReturns() async {
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); application.setActivationPolicy(policy) }
        window.orderFront(nil)
        AppDelegate(application: application, needsSetup: { false })
            .applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(window.isVisible)
        await drainMainQueue()
        XCTAssertFalse(window.isVisible)
    }

    func testApplicationUpdaterTracksStreamingIntentAndDoesNotRetainModel() {
        var model: AppModel? = AppModel(preferences: isolatedDefaults(), startServices: false,
                                       connection: ConnectionController(receiver: FakeStreamTransport()))
        weak var weakModel = model
        let driver = LifecycleUpdateDriver()
        let updater = WAMCApplication.makeUpdater(model: model!, enabled: true, makeDriver: { driver })
        updater.startOnce()
        XCTAssertEqual(driver.postponeInstallation?({}), false)
        model!.session.start()
        XCTAssertEqual(driver.postponeInstallation?({}), true)
        XCTAssertTrue(updater.installationDeferred)
        model!.session.stop()
        updater.resumeInstallationIfIdle()
        XCTAssertFalse(updater.installationDeferred)
        model = nil
        XCTAssertNil(weakModel)
        XCTAssertEqual(driver.postponeInstallation?({}), false)
    }
}

@MainActor
private final class LifecycleUpdateDriver: AppUpdateDriving {
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?
    func start() throws {}
    func checkInBackground() {}
    func checkManually() {}
}

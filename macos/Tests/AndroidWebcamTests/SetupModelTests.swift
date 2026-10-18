import AVFoundation
import Combine
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class SetupModelTests: XCTestCase {
    func testRefreshAndCompletionRequireInstalledSignedActiveSink() {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: true)
        let inspector = FakeSetupPackageInspector(installed: false, issue: "invalid signature")
        let model = SetupModel(environment: environment, packageInspector: inspector,
                               bundleURL: URL(fileURLWithPath: "/tmp/Test.app"))
        model.showSetup = true

        model.refresh()
        model.activateCamera()
        model.finish()

        XCTAssertFalse(model.installed)
        XCTAssertEqual(model.packageIssue, "invalid signature")
        XCTAssertTrue(model.sinkRegistered)
        XCTAssertEqual(environment.privacyPanes, [])
        XCTAssertFalse(model.extensionManager.status == .active)
        XCTAssertTrue(model.showSetup, "Setup remains open until all readiness checks pass")
    }

    func testCameraAuthorizationRoutesToRequestOrPrivacySettings() async {
        let environment = FakeSetupEnvironment(authorization: .notDetermined, sinkRegistered: false)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil))

        model.enableCameraAccess()
        XCTAssertEqual(environment.accessRequests, 1)
        environment.authorization = .authorized
        await Task.yield()
        XCTAssertEqual(model.cameraAuthorization, .authorized)

        environment.authorization = .denied
        model.refresh()
        model.enableCameraAccess()
        XCTAssertEqual(environment.privacyPanes, ["Privacy_Camera"])

        environment.authorization = .restricted
        model.refresh()
        model.enableCameraAccess()
        XCTAssertEqual(environment.privacyPanes, ["Privacy_Camera", "Privacy_Camera"])
    }

    func testSigningInspectorRejectsUnverifiableBundleWithActionableMessage() {
        XCTAssertNotNil(SystemSetupPackageInspector().signingIssue(
            bundleURL: URL(fileURLWithPath: "/tmp/does-not-exist.app")))
    }

    func testSigningValidationRejectsTestBundleWithoutAppExtensionEntitlements() {
        let issue = SetupModel.signingIssue(in: Bundle(for: SetupModelTests.self))
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("signing") == true)
    }

    func testFirstRunSetupRequiresInstalledApplicationAndCurrentSetupVersion() {
        let key = "wamc.setupVersion"
        let previousVersion = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousVersion { UserDefaults.standard.set(previousVersion, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(SetupModel.needsFirstRunSetup)
        UserDefaults.standard.set(SetupModel.version, forKey: key)
        XCTAssertTrue(SetupModel.needsFirstRunSetup,
                      "A current setup version still requires the installed Applications copy")
    }

    func testExtensionStatusDescriptionsAreActionableForEachState() {
        let cases: [(CameraExtensionManager.Status, String)] = [
            (.unknown, "Ready to activate"),
            (.notInstalled, "Not installed"),
            (.activating, "Installing"),
            (.requiresApproval, "Approval required"),
            (.disabled, "Enable Android Camera"),
            (.requiresRestart, "Restart your Mac"),
            (.active, "Active"),
            (.failed("request denied"), "request denied"),
        ]
        for (status, expectedText) in cases {
            XCTAssertTrue(status.description.contains(expectedText), "Unexpected description for \(status)")
        }
    }

    func testStartActivatesInstalledExtensionAndRefreshesReadiness() {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: true)
        let service = FakeCameraExtensionService(status: .unknown)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: true, issue: nil),
                               extensionService: service)

        model.start()
        defer { model.stop() }

        XCTAssertEqual(service.activationRequests, 1)
        XCTAssertEqual(service.refreshRequests, 1)
        XCTAssertTrue(model.sinkRegistered)
    }

    func testRefreshDoesNotQueryExtensionWhenPackageIsInvalid() {
        let service = FakeCameraExtensionService(status: .unknown)
        let model = SetupModel(environment: FakeSetupEnvironment(authorization: .authorized,
                                                                 sinkRegistered: false),
                               packageInspector: FakeSetupPackageInspector(installed: true,
                                                                           issue: "invalid signature"),
                               extensionService: service)

        model.refresh()

        XCTAssertEqual(service.refreshRequests, 0)
        XCTAssertEqual(service.activationRequests, 0)
    }

    func testExtensionActivationRoutesApprovalAndRestartStatesSafely() {
        let service = FakeCameraExtensionService(status: .requiresApproval)
        let model = SetupModel(environment: FakeSetupEnvironment(authorization: .authorized,
                                                                 sinkRegistered: false),
                               packageInspector: FakeSetupPackageInspector(installed: true, issue: nil),
                               extensionService: service,
                               bundleURL: URL(fileURLWithPath: "/Applications/WAMC.app"))

        model.activateCamera()
        XCTAssertEqual(service.settingsRequests, 1)
        XCTAssertEqual(service.activationRequests, 0)

        service.status = .disabled
        model.activateCamera()
        XCTAssertEqual(service.settingsRequests, 2)

        service.status = .requiresRestart
        model.activateCamera()
        XCTAssertEqual(service.activationRequests, 0)

        service.status = .unknown
        model.activateCamera()
        XCTAssertEqual(service.activationRequests, 1)
    }

    func testFinishOnlyPersistsSetupAfterExtensionBecomesActive() {
        let key = "wamc.setupVersion"
        let previousVersion = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previousVersion { UserDefaults.standard.set(previousVersion, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let service = FakeCameraExtensionService(status: .disabled)
        let model = SetupModel(environment: FakeSetupEnvironment(authorization: .authorized,
                                                                 sinkRegistered: true),
                               packageInspector: FakeSetupPackageInspector(installed: true, issue: nil),
                               extensionService: service,
                               bundleURL: URL(fileURLWithPath: "/Applications/WAMC.app"))
        model.showSetup = true
        model.refresh()

        model.finish()
        XCTAssertTrue(model.showSetup)
        XCTAssertNotEqual(UserDefaults.standard.integer(forKey: key), SetupModel.version)

        service.status = .active
        model.finish()
        XCTAssertFalse(model.showSetup)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), SetupModel.version)
    }

    func testFinishWaitsForRegisteredSinkEvenWhenExtensionIsActive() {
        let service = FakeCameraExtensionService(status: .active)
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: true, issue: nil),
                               extensionService: service)
        model.showSetup = true

        model.finish()
        XCTAssertTrue(model.showSetup)

        environment.registered = true
        model.refresh()
        model.finish()
        XCTAssertFalse(model.showSetup)
    }

    func testInstallationFailureLeavesSetupUsableAndDoesNotTerminate() async {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let installer = FakeApplicationInstaller(error: InstallationFailure.denied)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil),
                               installer: installer,
                               bundleURL: URL(fileURLWithPath: "/tmp/Staged.app"))

        await model.install(using: installer)

        XCTAssertEqual(installer.sources, [URL(fileURLWithPath: "/tmp/Staged.app")])
        XCTAssertFalse(model.installing)
        XCTAssertTrue(model.operationError?.contains("Could not install WAMC") == true)
        XCTAssertEqual(environment.terminationRequests, 0)
    }

    func testInstallationSuccessTerminatesCurrentApplication() async {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let installer = FakeApplicationInstaller(error: nil)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil),
                               installer: installer,
                               bundleURL: URL(fileURLWithPath: "/tmp/Staged.app"))

        await model.install(using: installer)

        XCTAssertNil(model.operationError)
        XCTAssertEqual(environment.terminationRequests, 1)
    }

    func testInstallInApplicationsRunsConfiguredInstallerAndReportsCompletion() async {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let installer = FakeApplicationInstaller(error: nil)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil),
                               installer: installer,
                               bundleURL: URL(fileURLWithPath: "/tmp/Staged.app"))
        let installed = expectation(description: "configured installer is called")
        installer.onInstall = { installed.fulfill() }

        model.installInApplications()
        await fulfillment(of: [installed], timeout: 1)

        XCTAssertEqual(installer.sources, [URL(fileURLWithPath: "/tmp/Staged.app")])
        XCTAssertEqual(environment.terminationRequests, 1)
        XCTAssertFalse(model.installing)
    }

    func testInstallationIsIgnoredWhenPackageIsAlreadyInstalledOrInvalid() async {
        let installer = FakeApplicationInstaller(error: nil)
        let installed = SetupModel(environment: FakeSetupEnvironment(authorization: .authorized,
                                                                      sinkRegistered: false),
                                   packageInspector: FakeSetupPackageInspector(installed: true, issue: nil),
                                   installer: installer)
        let invalid = SetupModel(environment: FakeSetupEnvironment(authorization: .authorized,
                                                                    sinkRegistered: false),
                                 packageInspector: FakeSetupPackageInspector(installed: false,
                                                                             issue: "invalid"),
                                 installer: installer)

        await installed.install(using: installer)
        await invalid.install(using: installer)
        installed.installInApplications()
        invalid.installInApplications()

        XCTAssertTrue(installer.sources.isEmpty)
        XCTAssertFalse(installed.installing)
        XCTAssertFalse(invalid.installing)
    }

    func testSystemInstallerStagesBundleAndLaunchesInstalledCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wamc-install-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Staged.app", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try Data("bundle payload".utf8).write(to: source.appendingPathComponent("Contents.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeApplicationLauncher()
        let installer = SystemApplicationInstaller(applicationsURL: applications, launcher: launcher)

        try await installer.install(source)

        let installed = applications.appendingPathComponent("WAMC.app", isDirectory: true)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents.txt"),
                                 encoding: .utf8), "bundle payload")
        XCTAssertEqual(launcher.launchedURLs, [installed])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["WAMC.app"])
    }

    func testSystemInstallerReplacesExistingApplicationBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wamc-install-replace-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Staged.app", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = applications.appendingPathComponent("WAMC.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try Data("new bundle".utf8).write(to: source.appendingPathComponent("Contents.txt"))
        try Data("old bundle".utf8).write(to: installed.appendingPathComponent("Contents.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeApplicationLauncher()
        let installer = SystemApplicationInstaller(applicationsURL: applications, launcher: launcher)

        try await installer.install(source)

        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents.txt"),
                                 encoding: .utf8), "new bundle")
        XCTAssertEqual(launcher.launchedURLs, [installed])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["WAMC.app"])
    }

    func testSystemInstallerPropagatesCopyAndLaunchFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wamc-install-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing.app")
        let launcher = FakeApplicationLauncher(error: InstallationFailure.denied)
        let installer = SystemApplicationInstaller(applicationsURL: root, launcher: launcher)

        do {
            try await installer.install(missing)
            XCTFail("Missing source should fail during staging")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertTrue(launcher.launchedURLs.isEmpty)

        let source = root.appendingPathComponent("Valid.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do {
            try await installer.install(source)
            XCTFail("Launch failure should be propagated")
        } catch {
            XCTAssertEqual(error.localizedDescription, "permission denied")
        }
        XCTAssertEqual(launcher.launchedURLs.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       ["Valid.app", "WAMC.app"].sorted())
    }
}

@MainActor
private final class FakeSetupEnvironment: SetupEnvironment {
    var authorization: AVAuthorizationStatus
    var registered: Bool
    private(set) var accessRequests = 0
    private(set) var privacyPanes: [String] = []
    private(set) var terminationRequests = 0

    init(authorization: AVAuthorizationStatus, sinkRegistered: Bool) {
        self.authorization = authorization
        registered = sinkRegistered
    }

    func cameraAuthorization() -> AVAuthorizationStatus { authorization }

    func requestCameraAccess(completion: @escaping (Bool) -> Void) {
        accessRequests += 1
        completion(true)
    }

    func sinkIsRegistered() -> Bool { registered }
    func openPrivacyPane(_ pane: String) { privacyPanes.append(pane) }
    func terminateApplication() { terminationRequests += 1 }
}

private enum InstallationFailure: LocalizedError {
    case denied
    var errorDescription: String? { "permission denied" }
}

private final class FakeApplicationLauncher: InstalledApplicationLaunching {
    private(set) var launchedURLs: [URL] = []
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    func launch(_ applicationURL: URL) async throws {
        launchedURLs.append(applicationURL)
        if let error { throw error }
    }
}

@MainActor
private final class FakeApplicationInstaller: ApplicationInstallationServicing {
    let error: Error?
    private(set) var sources: [URL] = []
    var onInstall: (() -> Void)?

    init(error: Error?) { self.error = error }

    func install(_ source: URL) async throws {
        sources.append(source)
        onInstall?()
        if let error { throw error }
    }
}

private struct FakeSetupPackageInspector: SetupPackageInspecting {
    let installed: Bool
    let issue: String?

    func isInstalled(bundleURL: URL) -> Bool { installed }
    func signingIssue(bundleURL: URL) -> String? { issue }
}

@MainActor
private final class FakeCameraExtensionService: CameraExtensionServicing {
    @Published var status: CameraExtensionManager.Status
    var statusPublisher: AnyPublisher<CameraExtensionManager.Status, Never> {
        $status.eraseToAnyPublisher()
    }
    private(set) var activationRequests = 0
    private(set) var refreshRequests = 0
    private(set) var settingsRequests = 0

    init(status: CameraExtensionManager.Status) { self.status = status }
    func activate() { activationRequests += 1 }
    func refreshStatus() { refreshRequests += 1 }
    func openSystemSettings() { settingsRequests += 1 }
}

extension SetupModelTests {
    func testAuthorizedCameraAccessDoesNotRequestOrOpenSettings() {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil))
        model.enableCameraAccess()
        XCTAssertEqual(environment.accessRequests, 0)
        XCTAssertTrue(environment.privacyPanes.isEmpty)
        model.openPrivacy("Privacy_LocalNetwork")
        XCTAssertEqual(environment.privacyPanes, ["Privacy_LocalNetwork"])
    }

    func testSystemPackageInspectorRequiresApplicationsLocation() {
        let inspector = SystemSetupPackageInspector()
        XCTAssertTrue(inspector.isInstalled(bundleURL: URL(fileURLWithPath: "/Applications/WAMC.app")))
        XCTAssertFalse(inspector.isInstalled(bundleURL: URL(fileURLWithPath: "/Volumes/WAMC/WAMC.app")))
        XCTAssertFalse(inspector.isInstalled(bundleURL: URL(fileURLWithPath: "/tmp/WAMC.app")))
    }

    func testSetupPollingRefreshesAuthorizationAndStopsCleanly() async {
        let environment = FakeSetupEnvironment(authorization: .authorized, sinkRegistered: false)
        let model = SetupModel(environment: environment,
                               packageInspector: FakeSetupPackageInspector(installed: false, issue: nil))
        model.start()
        defer { model.stop() }
        environment.authorization = .denied
        environment.registered = true
        let refreshed = expectation(description: "polling observes changed camera state")
        var observation: AnyCancellable?
        observation = model.$sinkRegistered.sink { registered in
            if registered { refreshed.fulfill() }
        }
        await fulfillment(of: [refreshed], timeout: 4)
        XCTAssertEqual(model.cameraAuthorization, .denied)
        observation?.cancel()
        model.stop()
        model.stop()
    }
}

extension SetupModelTests {
    func testSystemLauncherReportsMissingInstalledBundle() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("wamc-missing-\(UUID().uuidString).app")
        do {
            try await WorkspaceApplicationLauncher().launch(missing)
            XCTFail("A missing application must not report successful launch")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testSystemEnvironmentReadsAuthorizationWithoutPrompting() {
        XCTAssertEqual(SystemSetupEnvironment().cameraAuthorization(),
                       AVCaptureDevice.authorizationStatus(for: .video))
    }
}

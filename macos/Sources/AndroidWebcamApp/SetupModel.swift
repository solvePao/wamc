import AppKit
import AVFoundation
import Combine
import Security
import AndroidWebcamCore
import OSLog

@MainActor
protocol SetupEnvironment {
    func cameraAuthorization() -> AVAuthorizationStatus
    func requestCameraAccess(completion: @escaping (Bool) -> Void)
    func sinkIsRegistered() -> Bool
    func openPrivacyPane(_ pane: String)
    func terminateApplication()
}

struct SystemSetupEnvironment: SetupEnvironment {
    private let readAuthorization: (AVMediaType) -> AVAuthorizationStatus
    private let requestAccess: (AVMediaType, @escaping @Sendable (Bool) -> Void) -> Void
    private let readSinkRegistration: () -> Bool
    private let openURL: (URL) -> Bool
    private let terminate: (Any?) -> Void

    init(readAuthorization: @escaping (AVMediaType) -> AVAuthorizationStatus = AVCaptureDevice.authorizationStatus,
         requestAccess: @escaping (AVMediaType, @escaping @Sendable (Bool) -> Void) -> Void = AVCaptureDevice.requestAccess,
         readSinkRegistration: @escaping () -> Bool = VirtualCameraDevice.sinkIsRegistered,
         openURL: @escaping (URL) -> Bool = NSWorkspace.shared.open,
         terminate: @escaping (Any?) -> Void = NSApplication.shared.terminate) {
        self.readAuthorization = readAuthorization
        self.requestAccess = requestAccess
        self.readSinkRegistration = readSinkRegistration
        self.openURL = openURL
        self.terminate = terminate
    }

    func cameraAuthorization() -> AVAuthorizationStatus { readAuthorization(.video) }
    func requestCameraAccess(completion: @escaping (Bool) -> Void) { requestAccess(.video, completion) }
    func sinkIsRegistered() -> Bool { readSinkRegistration() }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        _ = openURL(url)
    }

    func terminateApplication() { terminate(nil) }
}

protocol SetupPackageInspecting {
    func isInstalled(bundleURL: URL) -> Bool
    func signingIssue(bundleURL: URL) -> String?
}

struct SystemSetupPackageInspector: SetupPackageInspecting {
    func isInstalled(bundleURL: URL) -> Bool {
        SetupReadiness.isApplicationsInstall(bundleURL.resolvingSymlinksInPath().path)
    }

    func signingIssue(bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL) else {
            return "The WAMC application bundle could not be inspected. Install a newly signed WAMC build."
        }
        return SetupModel.signingIssue(in: bundle)
    }
}

protocol ApplicationInstallationServicing {
    func install(_ source: URL) async throws
}

protocol ApplicationBundleFileManaging {
    func copyItem(at source: URL, to destination: URL) throws
    func fileExists(atPath path: String) -> Bool
    func replaceItem(at destination: URL, with source: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

struct FoundationApplicationBundleFileManager: ApplicationBundleFileManaging {
    private let manager = FileManager.default
    func copyItem(at source: URL, to destination: URL) throws {
        try manager.copyItem(at: source, to: destination)
    }
    func fileExists(atPath path: String) -> Bool { manager.fileExists(atPath: path) }
    func replaceItem(at destination: URL, with source: URL) throws {
        _ = try manager.replaceItemAt(destination, withItemAt: source)
    }
    func moveItem(at source: URL, to destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { try manager.removeItem(at: url) }
}

protocol InstalledApplicationLaunching {
    func launch(_ applicationURL: URL) async throws
}

struct WorkspaceApplicationLauncher: InstalledApplicationLaunching {
    func launch(_ applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

struct SystemApplicationInstaller: ApplicationInstallationServicing {
    private let applicationsURL: URL
    private let fileManager: ApplicationBundleFileManaging
    private let launcher: InstalledApplicationLaunching

    init(applicationsURL: URL = URL(fileURLWithPath: "/Applications"),
         fileManager: ApplicationBundleFileManaging = FoundationApplicationBundleFileManager(),
         launcher: InstalledApplicationLaunching = WorkspaceApplicationLauncher()) {
        self.applicationsURL = applicationsURL
        self.fileManager = fileManager
        self.launcher = launcher
    }

    func install(_ source: URL) async throws {
        let destination = applicationsURL.appendingPathComponent("WAMC.app", isDirectory: true)
        let staging = applicationsURL.appendingPathComponent(".WAMC-install-\(UUID().uuidString).app",
                                                             isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.replaceItem(at: destination, with: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        try await launcher.launch(destination)
    }
}

@MainActor
final class SetupModel: ObservableObject {
    static let version = 1
    static var needsFirstRunSetup: Bool {
        needsFirstRunSetup(preferences: .standard, bundleURL: Bundle.main.bundleURL)
    }

    static func needsFirstRunSetup(preferences: UserDefaults, bundleURL: URL) -> Bool {
        preferences.integer(forKey: "wamc.setupVersion") < version
            || !SetupReadiness.isApplicationsInstall(bundleURL.resolvingSymlinksInPath().path)
    }

    var requiresFirstRunSetup: Bool {
        Self.needsFirstRunSetup(preferences: preferences, bundleURL: bundleURL)
    }

    let extensionManager: CameraExtensionManager
    @Published var showSetup = false
    @Published private(set) var installed = false
    @Published private(set) var packageIssue: String?
    @Published private(set) var cameraAuthorization: AVAuthorizationStatus
    @Published private(set) var sinkRegistered = false
    @Published private(set) var operationError: String?
    @Published private(set) var installing = false
    var hasVerifiedVideo: () -> Bool = { false }
    var onRegistrationAvailable: (() -> Void)?

    var canFinish: Bool {
        installed && packageIssue == nil && sinkRegistered
            && extensionService.status == .active && hasVerifiedVideo()
    }

    private var observation: AnyCancellable?
    private var refreshTimer: Timer?
    private let environment: SetupEnvironment
    private let packageInspector: SetupPackageInspecting
    private let extensionService: CameraExtensionServicing
    private let installer: ApplicationInstallationServicing
    private let bundleURL: URL
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, environment: SetupEnvironment? = nil,
         packageInspector: SetupPackageInspecting = SystemSetupPackageInspector(),
         extensionManager: CameraExtensionManager? = nil,
         extensionService: CameraExtensionServicing? = nil,
         installer: ApplicationInstallationServicing = SystemApplicationInstaller(),
         bundleURL: URL = Bundle.main.bundleURL) {
        let activeEnvironment = environment ?? SystemSetupEnvironment()
        self.environment = activeEnvironment
        self.packageInspector = packageInspector
        self.extensionManager = extensionManager ?? CameraExtensionManager()
        self.extensionService = extensionService ?? self.extensionManager
        self.installer = installer
        self.bundleURL = bundleURL
        self.preferences = preferences
        cameraAuthorization = activeEnvironment.cameraAuthorization()
        inspectPackage()
        observation = self.extensionService.statusPublisher.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func start() {
        if installed, packageIssue == nil { extensionService.activate() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let authorization = environment.cameraAuthorization()
        if cameraAuthorization != authorization { cameraAuthorization = authorization }
        let registered = environment.sinkIsRegistered()
        if sinkRegistered != registered {
            sinkRegistered = registered
            if registered { onRegistrationAvailable?() }
        }
        if installed, packageIssue == nil { extensionService.refreshStatus() }
    }

    func enableCameraAccess() {
        switch cameraAuthorization {
        case .notDetermined:
            environment.requestCameraAccess { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .denied, .restricted:
            openPrivacy("Privacy_Camera")
        case .authorized: break
        @unknown default: openPrivacy("Privacy_Camera")
        }
    }

    func activateCamera() {
        guard installed, packageIssue == nil else { return }
        switch extensionService.status {
        case .requiresApproval, .disabled: extensionService.openSystemSettings()
        case .requiresRestart: break
        default: extensionService.activate()
        }
    }

    func repairCamera() {
        guard installed, packageIssue == nil else { return }
        extensionService.repair()
    }

    func openPrivacy(_ pane: String) {
        environment.openPrivacyPane(pane)
    }

    func finish() {
        guard canFinish else { return }
        preferences.set(Self.version, forKey: "wamc.setupVersion")
        showSetup = false
    }

    func installInApplications() {
        guard !installed, !installing, packageIssue == nil else { return }
        Task {
            await install(using: installer)
        }
    }

    func install(using installer: ApplicationInstallationServicing) async {
        guard !installed, !installing, packageIssue == nil else { return }
        installing = true
        operationError = nil
        do {
            try await installer.install(self.bundleURL)
            installing = false
            environment.terminateApplication()
        } catch {
            AppLogger.setup.error("Installing WAMC from \(self.bundleURL.path, privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
            operationError = "Could not install WAMC: \(error.localizedDescription) Drag WAMC into Applications, then open that copy."
            installing = false
        }
    }

    private func inspectPackage() {
        installed = packageInspector.isInstalled(bundleURL: bundleURL)
        packageIssue = packageInspector.signingIssue(bundleURL: bundleURL)
    }

    nonisolated static func signingInformation(at url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    nonisolated static func signingIssue(in bundle: Bundle,
        information: (URL) -> [String: Any]? = signingInformation,
        extensionBundle: (URL) -> Bundle? = Bundle.init(url:)) -> String? {
        guard let host = information(bundle.bundleURL),
              let hostEntitlements = host[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              hostEntitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              let team = host[kSecCodeInfoTeamIdentifier as String] as? String else {
            return "This copy is missing valid camera-extension signing. Install a newly signed WAMC build."
        }
        let extensionURL = bundle.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(CameraExtensionManager.extensionBundleID).systemextension")
        guard let info = information(extensionURL), info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let extensionBundle = extensionBundle(extensionURL),
              let cmio = extensionBundle.infoDictionary?["CMIOExtension"] as? [String: Any],
              cmio["CMIOExtensionMachServiceName"] as? String == "\(team).\(CameraExtensionManager.extensionBundleID)",
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              (entitlements["com.apple.security.application-groups"] as? [String])?.contains("\(team).com.androidwebcam.app") == true else {
            return "The bundled camera extension has inconsistent signing. Install a newly signed WAMC build."
        }
        return nil
    }
}

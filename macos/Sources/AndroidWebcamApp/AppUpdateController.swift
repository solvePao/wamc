import AppKit
import Combine
import Sparkle

@MainActor
protocol AppUpdateDriving: AnyObject {
    var postponeInstallation: ((@escaping () -> Void) -> Bool)? { get set }
    func start() throws
    func checkInBackground()
    func checkManually()
}

/// Owns launch checking and waits for an idle camera before replacing the app.
@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var installationDeferred = false
    private let enabled: Bool
    private let isStreaming: () -> Bool
    private let makeDriver: () -> AppUpdateDriving
    private let reportError: (Error) -> Void
    private var driver: AppUpdateDriving?
    private var didCheckAtLaunch = false
    private var pendingInstallation: (() -> Void)?
    private var streamObservation: AnyCancellable?

    init(enabled: Bool, isStreaming: @escaping () -> Bool,
         changes: AnyPublisher<Void, Never>? = nil,
         makeDriver: (() -> AppUpdateDriving)? = nil,
         reportError: ((Error) -> Void)? = nil) {
        self.enabled = enabled
        self.isStreaming = isStreaming
        self.makeDriver = makeDriver ?? { SparkleUpdateDriver() }
        self.reportError = reportError ?? { AppUpdateController.showError($0) }
        streamObservation = changes?.sink { [weak self] in
            // ObservableObject emits before its state changes.
            DispatchQueue.main.async { self?.resumeInstallationIfIdle() }
        }
    }

    func startOnce() {
        guard enabled, !didCheckAtLaunch else { return }
        didCheckAtLaunch = true
        do {
            try prepareDriver().checkInBackground()
        } catch {
            // A failed background check must not interrupt camera startup.
            AppLogger.setup.error("Update startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard enabled else { return }
        do { try prepareDriver().checkManually() }
        catch { reportError(error) }
    }

    func resumeInstallationIfIdle() {
        guard !isStreaming(), let install = pendingInstallation else { return }
        pendingInstallation = nil
        installationDeferred = false
        install()
    }

    private func prepareDriver() throws -> AppUpdateDriving {
        if let driver { return driver }
        let candidate = makeDriver()
        candidate.postponeInstallation = { [weak self] install in
            guard let self, self.isStreaming() else { return false }
            self.pendingInstallation = install
            self.installationDeferred = true
            return true
        }
        try candidate.start()
        driver = candidate
        return candidate
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving, SPUUpdaterDelegate {
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?
    private let bundle: Bundle
    private let controllerFactory: (SPUUpdaterDelegate) -> SPUStandardUpdaterController
    private lazy var controller = controllerFactory(self)

    init(bundle: Bundle = .main,
         controllerFactory: @escaping (SPUUpdaterDelegate) -> SPUStandardUpdaterController = {
             SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: $0, userDriverDelegate: nil)
         }) {
        self.bundle = bundle
        self.controllerFactory = controllerFactory
        super.init()
    }

    func start() throws {
        guard bundle.bundleURL.pathExtension == "app",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else {
            throw NSError(domain: "WAMC.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Updates require an installed WAMC release with a configured signing key."
            ])
        }
        // These are product policy: one launch check, with consent before download.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        try controller.updater.start()
    }

    func checkInBackground() { controller.updater.checkForUpdatesInBackground() }
    func checkManually() { controller.checkForUpdates(nil) }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation?(installHandler) ?? false
    }
}

import Foundation
import ServiceManagement
import OSLog

@MainActor
protocol LoginItemRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
protocol LoginItemServicing: LoginItemRegistering {
    func openLoginItemsSettings()
}

extension SMAppService: LoginItemRegistering {}

@MainActor
struct SystemLoginItemService: LoginItemServicing {
    private let registration: LoginItemRegistering
    private let openSettings: @MainActor () -> Void

    init(registration: LoginItemRegistering = SMAppService.mainApp,
         openSettings: @escaping @MainActor () -> Void = SMAppService.openSystemSettingsLoginItems) {
        self.registration = registration
        self.openSettings = openSettings
    }

    var status: SMAppService.Status { registration.status }
    func register() throws { try registration.register() }
    func unregister() async throws { try await registration.unregister() }
    func openLoginItemsSettings() { openSettings() }
}

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+; app targets 14+).
///
/// Default ON on first launch (background agent behaviour), with a
/// persisted opt-out: once the user turns it off we never re-register.
/// Registration only succeeds from the installed `/Applications/WAMC.app`;
/// dev builds fail gracefully and the toggle reflects the real status.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private let service: LoginItemServicing
    private let defaults: UserDefaults

    private static let optOutKey = "wamc.launchAtLoginOptOut"
    private static let didInitKey = "wamc.launchAtLoginInitialized"

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    init(service: LoginItemServicing? = nil, defaults: UserDefaults = .standard) {
        self.service = service ?? SystemLoginItemService()
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        status = service.status
    }

    /// Call once at launch: register by default unless the user opted out.
    func registerByDefaultIfNeeded() {
        if defaults.bool(forKey: Self.optOutKey) { refresh(); return }
        if service.status == .enabled { refresh(); return }
        register()
        defaults.set(true, forKey: Self.didInitKey)
    }

    func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            AppLogger.setup.error("Registering WAMC at login failed: \(error.localizedDescription, privacy: .private)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func unregister() {
        defaults.set(true, forKey: Self.optOutKey)
        Task {
            do {
                try await service.unregister()
                lastError = nil
            } catch {
                AppLogger.setup.error("Removing WAMC from login items failed: \(error.localizedDescription, privacy: .private)")
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            defaults.set(false, forKey: Self.optOutKey)
            register()
        } else {
            unregister()
        }
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }
}

import Foundation
import Network
import dnssd
import AndroidWebcamCore

struct WifiAdvertisement {
    let instanceName: String
    let txt: [String: String]
    let endpoint: NWEndpoint
}

/// Browses Bonjour for WAMC phones (`_wamc._tcp`) on the local network.
///
/// Devices are keyed by the stable TXT `id` (instance names can be
/// auto-renamed on conflict). The `NWEndpoint` for each device is kept
/// here so `StreamReceiver` can connect without touching an IP address.
final class WifiDiscovery: ObservableObject {
    enum LifecycleState: Equatable {
        case off
        case searching
        case ready
        case waiting(String)
        case failed(String)
        case accessDenied(String)

        fileprivate var logName: String {
            switch self {
            case .off: return "off"
            case .searching: return "searching"
            case .ready: return "ready"
            case .waiting: return "waiting"
            case .failed: return "failed"
            case .accessDenied: return "accessDenied"
            }
        }
    }

    enum BrowserStatus {
        case ready
        case failed(String)
        case waiting(String)
        case other
    }

    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var statusText = "Wi-Fi discovery off"
    @Published private(set) var lifecycleState: LifecycleState = .off

    /// Fired on the main queue whenever the device set changes.
    var onDevicesChanged: (([DiscoveredDevice]) -> Void)?

    private var browser: NWBrowser?
    private var endpointsById: [String: NWEndpoint] = [:]
    private let queue = DispatchQueue(label: "awc.wifi-discovery")

    private let startBrowser: (NWBrowser, DispatchQueue) -> Void

    init(startBrowser: ((NWBrowser, DispatchQueue) -> Void)? = nil) {
        self.startBrowser = startBrowser ?? { $0.start(queue: $1) }
    }

    func endpoint(for device: DiscoveredDevice) -> NWEndpoint? {
        endpointsById[device.id]
    }

    func endpoint(forId id: String) -> NWEndpoint? { endpointsById[id] }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: WamcDiscovery.serviceType, domain: nil),
            using: .tcp)
        self.browser = browser
        updateLifecycle(.searching)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.applyBrowserStatus(.ready)
                case .failed(let error):
                    self.logBrowserError(error)
                    self.applyBrowserError(error, waiting: false)
                case .waiting(let error):
                    self.logBrowserError(error)
                    self.applyBrowserError(error, waiting: true)
                default: self.applyBrowserStatus(.other)
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let advertisements: [WifiAdvertisement] = results.compactMap { result in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                let name: String
                if case .service(let serviceName, _, _, _) = result.endpoint {
                    name = serviceName
                } else {
                    name = ""
                }
                return WifiAdvertisement(instanceName: name, txt: txt.dictionary, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.apply(advertisements)
            }
        }
        startBrowser(browser, queue)
    }

    /// Replace the browser without discarding endpoints used by an active session.
    func refresh(recoverOnly: Bool = false) {
        if recoverOnly, browser != nil {
            switch lifecycleState {
            case .searching, .ready: return
            case .off, .waiting, .failed, .accessDenied: break
            }
        }
        let previousBrowser = browser
        browser = nil
        previousBrowser?.cancel()
        start()
    }

    func apply(_ advertisements: [WifiAdvertisement]) {
        var parsed: [DiscoveredDevice] = []
        var endpoints: [String: NWEndpoint] = [:]
        for advertisement in advertisements {
            guard let device = DiscoveredDevice.parseTXT(advertisement.txt,
                                                         instanceName: advertisement.instanceName),
                  !device.isEmulator else { continue }
            // One entry per stable id; newest advertisement wins.
            if let existing = parsed.firstIndex(where: { $0.id == device.id }) {
                parsed[existing] = device
            } else {
                parsed.append(device)
            }
            endpoints[device.id] = advertisement.endpoint
        }
        parsed.sort { $0.displayName < $1.displayName }
        devices = parsed
        endpointsById = endpoints
        updateLifecycle(.ready)
        onDevicesChanged?(parsed)
    }

    func applyBrowserStatus(_ status: BrowserStatus) {
        switch status {
        case .ready: updateLifecycle(.ready)
        case .failed(let message): updateLifecycle(.failed(message))
        case .waiting(let message): updateLifecycle(.waiting(message))
        case .other: break
        }
    }

    private func updateLifecycle(_ state: LifecycleState) {
        if lifecycleState != state {
            AppLogger.discovery.info("Wi-Fi discovery state: \(state.logName, privacy: .public)")
        }
        lifecycleState = state
        switch state {
        case .off: statusText = "Wi-Fi discovery off"
        case .searching: statusText = "Searching for phones on Wi-Fi…"
        case .ready:
            statusText = devices.isEmpty
                ? "No phones found on this Wi-Fi network yet"
                : "Found \(devices.count) phone(s) on Wi-Fi"
        case .failed(let message): statusText = "Wi-Fi discovery failed: \(message)"
        case .waiting(let message): statusText = "Wi-Fi discovery waiting: \(message)"
        case .accessDenied(let message):
            statusText = "Local Network access is unavailable. Allow WAMC in System Settings → Privacy & Security → Local Network, then refresh. \(message)"
        }
    }

    private func applyBrowserError(_ error: NWError, waiting: Bool) {
        if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied || code == kDNSServiceErr_NotPermitted {
            updateLifecycle(.accessDenied(error.localizedDescription))
        } else {
            applyBrowserStatus(waiting ? .waiting(error.localizedDescription) : .failed(error.localizedDescription))
        }
    }

    private func logBrowserError(_ error: NWError) {
        // Network error domains and numeric codes contain no phone identity/address.
        let code: String
        switch error {
        case .posix(let value): code = "posix:\(value.rawValue)"
        case .dns(let value): code = "dns:\(value)"
        case .tls(let value): code = "tls:\(value)"
        default: code = "unknown"
        }
        AppLogger.discovery.warning("Wi-Fi discovery error \(code, privacy: .public): \(error.localizedDescription, privacy: .private)")
    }

    func stop() {
        let stoppedBrowser = browser
        browser = nil
        stoppedBrowser?.cancel()
        devices = []
        endpointsById = [:]
        updateLifecycle(.off)
    }
}

/// UserDefaults-backed trust store. Pure decisions live in
/// `TrustedDevices` (AndroidWebcamCore, unit-tested).
@MainActor
final class TrustedDeviceStore: ObservableObject {
    @Published private(set) var trusted: TrustedDevices

    private static let key = "wamc.trustedDeviceIds"

    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let saved = preferences.stringArray(forKey: Self.key) ?? []
        trusted = TrustedDevices(trustedIds: Set(saved))
    }

    func isTrusted(_ id: String) -> Bool { trusted.isTrusted(id) }

    func trust(_ id: String) {
        trusted.trust(id)
        persist()
    }

    func untrust(_ id: String) {
        trusted.untrust(id)
        persist()
    }

    private func persist() {
        preferences.set(Array(trusted.trustedIds), forKey: Self.key)
    }
}

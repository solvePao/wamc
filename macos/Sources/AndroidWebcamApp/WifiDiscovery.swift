import Foundation
import Network
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
    enum BrowserStatus {
        case ready
        case failed(String)
        case waiting(String)
        case other
    }

    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var statusText = "Wi-Fi discovery off"

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
        statusText = "Searching for phones on Wi-Fi…"
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.applyBrowserStatus(.ready)
                case .failed(let error): self.applyBrowserStatus(.failed(error.localizedDescription))
                case .waiting(let error): self.applyBrowserStatus(.waiting(error.localizedDescription))
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
        statusText = parsed.isEmpty
            ? "No phones found on this Wi-Fi network yet"
            : "Found \(parsed.count) phone(s) on Wi-Fi"
        onDevicesChanged?(parsed)
    }

    func applyBrowserStatus(_ status: BrowserStatus) {
        switch status {
        case .ready:
            statusText = devices.isEmpty
                ? "No phones found on this Wi-Fi network yet"
                : "Found \(devices.count) phone(s) on Wi-Fi"
        case .failed(let message): statusText = "Wi-Fi discovery failed: \(message)"
        case .waiting(let message): statusText = "Wi-Fi discovery waiting: \(message)"
        case .other: break
        }
    }

    func stop() {
        let stoppedBrowser = browser
        browser = nil
        stoppedBrowser?.cancel()
        devices = []
        endpointsById = [:]
        statusText = "Wi-Fi discovery off"
    }
}

/// UserDefaults-backed trust store. Pure decisions live in
/// `TrustedDevices` (AndroidWebcamCore, unit-tested).
@MainActor
final class TrustedDeviceStore: ObservableObject {
    @Published private(set) var trusted: TrustedDevices

    private static let key = "wamc.trustedDeviceIds"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
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
        UserDefaults.standard.set(Array(trusted.trustedIds), forKey: Self.key)
    }
}

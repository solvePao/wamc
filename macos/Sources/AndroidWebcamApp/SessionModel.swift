import Combine
import Foundation
import Network
import AndroidWebcamCore

struct SessionActionSnapshot: Equatable {
    enum Action: Equatable { case start, stop, cancel, none }
    let action: Action
    let title: String
    let status: String
    let sourceLabel: String
    let symbol: String
    var enabled = true
    var isProgress = false
}

/// Coordinates the user's streaming intent with transport readiness. Connection
/// setup and camera decoding remain owned by their existing components.
@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var selectedSource: ConnectionTarget = .usb(serial: nil)
    @Published private(set) var switching = false
    @Published private(set) var trustRequest: DiscoveredDevice?
    @Published var startsAutomatically: Bool {
        didSet { UserDefaults.standard.set(startsAutomatically, forKey: Self.automaticKey) }
    }
    private(set) var wantsStreaming = false
    var onStartCamera: (() -> Void)?
    var endpointForDevice: ((DiscoveredDevice) -> NWEndpoint?)?
    var isTrusted: ((DiscoveredDevice) -> Bool)?
    var trustDevice: ((DiscoveredDevice) -> Void)?

    private static let automaticKey = "wamc.startStreamingAutomatically"
    private let connection: ConnectionController
    private var operation = UUID()
    private var explicitlySelected = false

    init(connection: ConnectionController) {
        self.connection = connection
        let preferences = UserDefaults.standard
        if let saved = preferences.object(forKey: Self.automaticKey) as? Bool {
            startsAutomatically = saved
        } else {
            let connect = preferences.object(forKey: "wamc.autoConnect") as? Bool ?? true
            let start = preferences.object(forKey: "wamc.autoStart") as? Bool ?? true
            startsAutomatically = connect && start
            preferences.set(startsAutomatically, forKey: Self.automaticKey)
        }
    }

    func start(manual: Bool = true) {
        if case .disconnecting = connection.state { return }
        if manual, case .wifi(let phone) = selectedSource, isTrusted?(phone) != true {
            trustDevice?(phone)
        }
        operation = UUID()
        wantsStreaming = true
        if connection.state.isConnected && matchesSelection(connection.state.target) {
            onStartCamera?()
        } else if connection.state == .disconnected {
            connectSelection(manual: manual)
        } else {
            switchSelection(manual: manual)
        }
    }

    func stop() {
        operation = UUID()
        wantsStreaming = false
        explicitlySelected = true
        switching = false
        trustRequest = nil
        connection.disconnect(stopCamera: true)
    }

    func select(_ source: ConnectionTarget, explicit: Bool = true) {
        guard !sameSource(source, selectedSource) else {
            explicitlySelected = explicitlySelected || explicit
            trustRequest = nil
            return
        }
        if wantsStreaming, case .wifi(let phone) = source, isTrusted?(phone) != true {
            trustRequest = phone
            return
        }
        commitSelection(source, explicit: explicit)
    }

    func confirmTrust(_ phone: DiscoveredDevice) {
        trustRequest = nil
        trustDevice?(phone)
        commitSelection(.wifi(phone), explicit: true)
    }

    func cancelTrust() { trustRequest = nil }

    func connectionReady() {
        guard wantsStreaming else { return }
        switching = false
        onStartCamera?()
    }

    func connectionChanged(_ state: ConnectionState) {
        if case .disconnected = state, !switching || connection.failureMessage != nil {
            switching = false
            wantsStreaming = false
        }
    }

    /// Discovery selects an initial source, then shares the same Start path as
    /// the main button. A selected source is never silently replaced by polling.
    func discovered(usb: [AndroidDevice], wifi: [DiscoveredDevice]) {
        let cable = usb.first(where: { $0.state == "device" }).map { ConnectionTarget.usb(serial: $0.id) }
        let trustedPhone = wifi.first(where: { isTrusted?($0) == true }).map(ConnectionTarget.wifi)
        if !explicitlySelected {
            let preferred: ConnectionTarget = cable == nil ? (trustedPhone ?? .usb(serial: nil)) : .usb(serial: nil)
            if !wantsStreaming && connection.state == .disconnected {
                if selectedSource != preferred { selectedSource = preferred }
            } else if startsAutomatically, cable != nil, selectedSource.transport == .wifi {
                select(preferred, explicit: false)
            }
        }
        guard startsAutomatically, !wantsStreaming, connection.state == .disconnected,
              connection.canAutomaticallyConnect(to: selectedSource.transport == .usb ? (cable ?? selectedSource) : selectedSource) else { return }
        let available: Bool
        switch selectedSource {
        case .usb(let serial): available = usb.contains { $0.state == "device" && (serial == nil || $0.id == serial) }
        case .wifi(let phone): available = isTrusted?(phone) == true && wifi.contains { $0.id == phone.id }
        case .address: available = false
        }
        if available { start(manual: false) }
    }

    func snapshot(feed: FeedState, sourceLabel: String) -> SessionActionSnapshot {
        if switching {
            return .init(action: .cancel, title: "Cancel", status: "Switching to \(sourceLabel)…",
                         sourceLabel: sourceLabel, symbol: "xmark", isProgress: true)
        }
        switch connection.state {
        case .disconnecting:
            return .init(action: .none, title: "Stopping…", status: "Stopping stream…",
                         sourceLabel: sourceLabel, symbol: "stop.fill", enabled: false, isProgress: true)
        case .connecting:
            return .init(action: .cancel, title: "Cancel", status: "Connecting to \(sourceLabel)…",
                         sourceLabel: sourceLabel, symbol: "xmark", isProgress: true)
        case .connected:
            if feed == .idle {
                return .init(action: .start, title: "Start stream", status: "Connected; camera stopped",
                             sourceLabel: sourceLabel, symbol: "play.fill")
            }
            let status: String
            switch feed {
            case .starting: status = "Starting camera…"
            case .updating: status = "Applying quality…"
            case .stalled: status = "No feed. Check the phone or stop and start again."
            default: status = "Streaming over \(selectedSource.transport == .usb ? "USB" : "Wi-Fi")"
            }
            return .init(action: .stop, title: "Stop stream", status: status, sourceLabel: sourceLabel,
                         symbol: "stop.fill", isProgress: feed == .starting || feed == .updating)
        case .disconnected:
            let failure = connection.failureMessage
            let needsTrust: Bool
            if case .wifi(let phone) = selectedSource { needsTrust = isTrusted?(phone) != true }
            else { needsTrust = false }
            return .init(action: .start, title: needsTrust ? "Trust & Start" : (failure == nil ? "Start stream" : "Retry stream"),
                         status: failure ?? "Ready to start", sourceLabel: sourceLabel, symbol: "play.fill")
        }
    }

    func matchesSelection(_ source: ConnectionTarget?) -> Bool {
        source.map { sameSource($0, selectedSource) } ?? false
    }

    func isSelected(_ source: ConnectionTarget) -> Bool { sameSource(source, selectedSource) }

    private func sameSource(_ lhs: ConnectionTarget, _ rhs: ConnectionTarget) -> Bool {
        if lhs.transport == .usb && rhs.transport == .usb { return true }
        return lhs.key == rhs.key
    }

    private func commitSelection(_ source: ConnectionTarget, explicit: Bool) {
        connection.clearFailure()
        selectedSource = source.transport == .usb ? .usb(serial: nil) : source
        explicitlySelected = explicitlySelected || explicit
        if wantsStreaming { switchSelection(manual: explicit) }
    }

    private func switchSelection(manual: Bool) {
        let token = UUID()
        operation = token
        switching = true
        connection.disconnect(stopCamera: true, suppressAutomaticConnection: false) { [weak self] in
            guard let self, self.operation == token, self.wantsStreaming else { return }
            self.connectSelection(manual: manual)
        }
    }

    private func connectSelection(manual: Bool) {
        let endpoint: NWEndpoint?
        if case .wifi(let phone) = selectedSource { endpoint = endpointForDevice?(phone) }
        else { endpoint = nil }
        connection.connect(to: selectedSource, endpoint: endpoint, manual: manual)
        // A missing endpoint can fail synchronously, before a HELLO is possible.
        if connection.state == .disconnected {
            switching = false
            wantsStreaming = false
        }
    }
}

import Combine
import Foundation
import Network
import AndroidWebcamCore
import OSLog

/// The selected identity stays attached to connecting, connected and teardown states.
enum ConnectionTarget: Equatable {
    case usb(serial: String?)
    case wifi(DiscoveredDevice)
    case address(String, UInt16)

    var transport: TransportKind {
        if case .usb = self { return .usb }
        return .wifi
    }

    var key: String {
        switch self {
        case .usb(let serial): return "usb:\(serial ?? "auto")"
        case .wifi(let device): return "wifi:\(device.id)"
        case .address(let host, let port): return "address:\(host):\(port)"
        }
    }

    var label: String {
        switch self {
        case .usb: return "USB"
        case .wifi(let device): return device.displayName
        case .address(let host, let port): return "\(host):\(port)"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting(ConnectionTarget)
    case connected(ConnectionTarget)
    case disconnecting(ConnectionTarget)

    var target: ConnectionTarget? {
        switch self {
        case .disconnected: return nil
        case .connecting(let target), .connected(let target), .disconnecting(let target): return target
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// Owns transport attempts and their deadline. Video and camera commands stay
/// with AppModel; views never manipulate receiver state directly.
@MainActor
final class ConnectionController: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    private(set) var automaticConnectionSuppressed = false
    private(set) var manuallySelected = false
    private(set) var identityMismatch = false
    private(set) var failureMessage: String?
    var onStateChange: ((ConnectionState, String) -> Void)?
    var onHello: (([String: String], Bool) -> Void)?
    var onStreamEvent: ((StreamReceiver.Event) -> Void)?

    private let receiver: StreamTransport
    private var attempt = UUID()
    private var timeout: Task<Void, Never>?
    private var usbSetup: USBConnectionSetup?
    private var forwarded: USBConnectionSetup.PreparedConnection?
    private var blockedTargets: Set<String> = []
    private var availableUSBKeys: Set<String> = []
    private var disconnectCompletions: [() -> Void] = []

    init(receiver: StreamTransport = StreamReceiver()) {
        self.receiver = receiver
        receiver.onEvent = { [weak self] attempt, event in
            DispatchQueue.main.async { self?.receive(event, attempt: attempt) }
        }
    }

    func canAutomaticallyConnect(to target: ConnectionTarget) -> Bool {
        !automaticConnectionSuppressed && !blockedTargets.contains(target.key)
            && (target.transport != .usb || !blockedTargets.contains("usb:auto"))
    }

    func updateAvailableTargets(_ targets: [ConnectionTarget]) {
        let usbKeys = Set(targets.filter { $0.transport == .usb }.map(\.key))
        if usbKeys != availableUSBKeys { blockedTargets.remove("usb:auto") }
        availableUSBKeys = usbKeys
        var available = Set(targets.map(\.key))
        if !usbKeys.isEmpty { available.insert("usb:auto") }
        blockedTargets.formIntersection(available)
    }

    func connect(to target: ConnectionTarget, endpoint: NWEndpoint? = nil, manual: Bool) {
        if case .disconnecting = state { return }
        if manual {
            automaticConnectionSuppressed = false
            blockedTargets.remove(target.key)
        }
        guard state.target != target || state == .disconnected else { return }
        invalidateAttempt()
        failureMessage = nil
        manuallySelected = manual
        identityMismatch = false
        let id = UUID()
        attempt = id
        transition(.connecting(target), "Connecting to \(target.label)…")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        armTimeout(attempt: id, message: "Could not connect to \(target.label) within 5 seconds.")
        switch target {
        case .usb(let serial):
            let setup = USBConnectionSetup(deadline: deadline)
            usbSetup = setup
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try setup.prepare(preferredSerial: serial) }
                Task { @MainActor in
                    guard let self, self.attempt == id, self.state.isConnecting else {
                        if case .success(let prepared) = result {
                            USBConnectionSetup.removeForward(serial: prepared.serial, port: prepared.port)
                        }
                        return
                    }
                    switch result {
                    case .success(let prepared):
                        self.forwarded = prepared
                        let selected = ConnectionTarget.usb(serial: prepared.serial)
                        let warnings = prepared.warnings.joined(separator: " ")
                        self.transition(.connecting(selected), "Connecting through USB…" + (warnings.isEmpty ? "" : " \(warnings)"))
                        self.receiver.start(endpoint: .hostPort(host: "127.0.0.1",
                            port: NWEndpoint.Port(rawValue: prepared.port)!), attempt: id)
                    case .failure(let error):
                        AppLogger.connection.error("USB connection preparation failed: \(error.localizedDescription, privacy: .private)")
                        self.fail(error.localizedDescription)
                    }
                }
            }
        case .wifi:
            guard let endpoint else {
                AppLogger.connection.warning("Wi-Fi target became unavailable before connect")
                fail("That phone is no longer reachable on Wi-Fi.")
                return
            }
            receiver.start(endpoint: endpoint, attempt: id)
        case .address(let host, let port):
            guard port > 0, let port = NWEndpoint.Port(rawValue: port) else {
                AppLogger.connection.error("Rejected invalid phone port \(port, privacy: .public)")
                fail("Invalid phone port.")
                return
            }
            receiver.start(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port), attempt: id)
        }
    }

    func clearFailure() { failureMessage = nil }

    func sendControl(_ fields: [(String, String)]) {
        guard state.isConnected else { return }
        receiver.sendControl(fields, attempt: attempt, completion: nil)
    }

    func disconnect(stopCamera: Bool = false, suppressAutomaticConnection: Bool = true,
                    completion: (() -> Void)? = nil) {
        if suppressAutomaticConnection { automaticConnectionSuppressed = true }
        failureMessage = nil
        guard let target = state.target else {
            completion?()
            return
        }
        if let completion { disconnectCompletions.append(completion) }
        if case .disconnecting = state { return }
        let id = attempt
        let wasConnected = state.isConnected
        transition(.disconnecting(target), stopCamera ? "Stopping camera…" : "Disconnecting…")
        timeout?.cancel()
        usbSetup?.cancel()
        if stopCamera && wasConnected {
            receiver.sendControl([("cmd", "stop")], attempt: id) { [weak self] in
                Task { @MainActor in self?.finishDisconnect(attempt: id) }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.finishDisconnect(attempt: id)
            }
        } else {
            finishDisconnect(attempt: id)
        }
    }

    func usbWasRemoved() {
        guard state.target?.transport == .usb else { return }
        fail("USB phone disconnected.")
    }

    private func receive(_ event: StreamReceiver.Event, attempt id: UUID) {
        guard attempt == id, let target = state.target else { return }
        guard state.isConnected || state.isConnecting else { return }
        switch event {
        case .transportReady:
            // Capability exchange is safe before identity validation; Start is not.
            receiver.sendControl([("cmd", "hello"), ("codecs", "avc,hevc"), ("configV2", "1")],
                                 attempt: id, completion: nil)
        case .hello(let info):
            guard let model = info["model"], !model.isEmpty else { return }
            if case .wifi(let phone) = target, info["id"] != phone.id {
                AppLogger.connection.error("Wi-Fi phone identity did not match discovery record")
                identityMismatch = true
                fail("Wi-Fi phone identity mismatch — disconnected.")
                return
            }
            let firstHello = !state.isConnected
            if firstHello {
                timeout?.cancel()
                transition(.connected(target), "Connected — waiting for video…")
            }
            onHello?(info, firstHello)
        case .transportLost:
            if state.isConnected {
                transition(.connecting(target), "Connection lost — reconnecting…")
                armTimeout(attempt: id, message: "Connection lost. Connect again to retry.")
            }
        default:
            guard state.isConnected else { return }
            onStreamEvent?(event)
        }
    }

    private func armTimeout(attempt id: UUID, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.attempt == id, self.state.isConnecting else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        if let target = state.target { blockedTargets.insert(target.key) }
        failureMessage = message
        completeDisconnection(message)
    }

    private func finishDisconnect(attempt id: UUID) {
        guard attempt == id else { return }
        completeDisconnection("Disconnected.")
    }

    private func completeDisconnection(_ message: String) {
        let completions = disconnectCompletions
        invalidateAttempt()
        manuallySelected = false
        transition(.disconnected, message)
        completions.forEach { $0() }
    }

    private func invalidateAttempt() {
        disconnectCompletions.removeAll()
        attempt = UUID()
        timeout?.cancel()
        timeout = nil
        usbSetup?.cancel()
        usbSetup = nil
        receiver.stop()
        if let forwarded {
            USBConnectionSetup.removeForward(serial: forwarded.serial, port: forwarded.port)
        }
        forwarded = nil
    }

    private func transition(_ state: ConnectionState, _ message: String) {
        self.state = state
        onStateChange?(state, message)
    }
}

import Foundation
import AndroidWebcamCore

/// Shared session actions for the window, source rows, and native menus.
extension AppModel {
    var selectedSource: ConnectionTarget { session.selectedSource }
    var trustRequest: DiscoveredDevice? { session.trustRequest }

    var startStreamingAutomatically: Bool {
        get { session.startsAutomatically }
        set { session.startsAutomatically = newValue }
    }

    var sessionAction: SessionActionSnapshot {
        let sourceLabel: String
        switch selectedSource {
        case .usb(let serial):
            let phone = devices.first(where: { serial == nil || $0.id == serial })?.model
            sourceLabel = phone.map { "\($0) · USB" } ?? "USB"
        case .adb: sourceLabel = "ADB · Development"
        case .wifi(let phone): sourceLabel = "\(phone.displayName) · Wi-Fi"
        case .address(let host, let port): sourceLabel = "\(host):\(port) · Network"
        }
        return session.snapshot(feed: feedState, sourceLabel: sourceLabel)
    }

    func startSession() { session.start() }
    func stopSession() { session.stop() }
    func cancelSession() { session.stop() }
    func selectSource(_ target: ConnectionTarget) { session.select(target) }
    func confirmSourceTrust(_ phone: DiscoveredDevice) { session.confirmTrust(phone) }
    func cancelSourceTrust() { session.cancelTrust() }
    func isSourceSelected(_ target: ConnectionTarget) -> Bool { session.isSelected(target) }

    func isSourceActive(_ target: ConnectionTarget) -> Bool {
        guard connected, let active = connectionState.target else { return false }
        if case .usb = target, case .usb = active { return true }
        if case .adb = target, case .adb = active { return true }
        return active.key == target.key
    }

    func performSessionAction() {
        switch sessionAction.action {
        case .start: startSession()
        case .stop: stopSession()
        case .cancel: cancelSession()
        case .none: break
        }
    }

    func useManualAddress() {
        let raw = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count), let host = components.first, !host.isEmpty else {
            statusText = "Enter an address like 192.168.1.20 or 192.168.1.20:27183"
            return
        }
        let port = components.count == 2 ? UInt16(components[1]) : UInt16(27183)
        guard let port, port > 0 else { statusText = "Enter a port between 1 and 65535."; return }
        selectSource(.address(String(host), port))
    }

    var visibleWifiDevices: [DiscoveredDevice] {
        var phones = discoveredDevices
        for target in [connectionState.target, selectedSource] {
            if case .wifi(let phone) = target, !phones.contains(where: { $0.id == phone.id }) {
                phones.append(phone)
            }
        }
        return phones
    }
}

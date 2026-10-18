import Foundation

/// Pure auto-connect/auto-start state machine: plug transitions, an explicit
/// Stop latch, and the "we already asked" flag. The Mac app owns one and
/// mirrors nothing else; unit tested.
public struct AutoStartPolicy {
    /// Set by explicit Stop/Disconnect; cleared on device-set change or Start.
    public var userStopped = false
    /// True after we sent `start` until stop/disconnect proves otherwise.
    public var streamCommanded = false
    public private(set) var lastDeviceId: String?

    public init() {}

    /// Plug/unplug (or serial swap) clears the Stop latch for the new arrival.
    public mutating func deviceListChanged(currentId: String?) {
        if currentId != lastDeviceId {
            lastDeviceId = currentId
            userStopped = false
        }
    }

    public func shouldConnect(devicePresent: Bool, connected: Bool, autoConnect: Bool) -> Bool {
        devicePresent && !connected && !userStopped && autoConnect
    }

    /// Call on live connection: start only when wanted, unlatched, not yet asked.
    public func shouldAutoStart(autoStart: Bool) -> Bool {
        autoStart && !userStopped && !streamCommanded
    }

    public mutating func manualConnect() { userStopped = false }

    public mutating func didSendStart() { streamCommanded = true; userStopped = false }

    public mutating func didSendStop() { streamCommanded = false; userStopped = true }

    /// A drop is not a decision: forget the in-flight start so a reconnect
    /// re-asks, but keep the Stop latch untouched (only buttons set it).
    public mutating func didDisconnect() { streamCommanded = false }

    public mutating func manualDisconnect() { streamCommanded = false; userStopped = true }
}

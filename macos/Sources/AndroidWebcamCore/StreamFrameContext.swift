import Foundation

/// Immutable orientation and identity of one decoder configuration.
public struct StreamFrameContext: Equatable {
    public let connectionEpoch: UInt64
    public let configurationRevision: UInt64
    public let rotation: Int
}

/// Shared by the receiver queue and MainActor to reject delayed work.
public final class StreamFrameContextTracker {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var configurationKey: String?
    private var context: StreamFrameContext?

    public init() {}

    public var connectionEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    @discardableResult
    public func advanceConnection() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        clearConfiguration()
        return epoch
    }

    public func resetConfiguration() {
        lock.lock(); defer { lock.unlock() }
        clearConfiguration()
    }

    /// A Start command may be deferred by Android while an existing stream stays live.
    public func allowRepeatedConfiguration() {
        lock.lock(); defer { lock.unlock() }
        configurationKey = nil
    }

    public func configure(key: String, rotation: Int) -> StreamFrameContext? {
        lock.lock(); defer { lock.unlock() }
        guard configurationKey != key else { return nil }
        configurationKey = key
        revision &+= 1
        let next = StreamFrameContext(connectionEpoch: epoch,
            configurationRevision: revision, rotation: rotation & 3)
        context = next
        return next
    }

    public func accepts(_ candidate: StreamFrameContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return context == candidate
    }

    private func clearConfiguration() {
        revision &+= 1
        configurationKey = nil
        context = nil
    }
}

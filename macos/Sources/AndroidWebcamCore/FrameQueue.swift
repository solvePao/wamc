import Foundation
import CoreVideo

/// Latest-wins frame queue (capacity 2). Old frames drop instead of
/// accumulating latency; the newest frame is always what preview shows.
public final class LatestFrameQueue {
    private let lock = NSLock()
    private var frames: [CVPixelBuffer] = []
    private let capacity: Int
    public private(set) var droppedCount = 0
    public private(set) var enqueuedCount = 0

    public init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    public func enqueue(_ frame: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        enqueuedCount += 1
        if frames.count >= capacity {
            frames.removeFirst(frames.count - capacity + 1)
            droppedCount += 1
        }
        frames.append(frame)
    }

    public func dequeueLatest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let latest = frames.last else { return nil }
        droppedCount += frames.count - 1
        frames.removeAll()
        return latest
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
    }
}

/// Exponential reconnect backoff: 0.5s doubling to an 8s cap.
public struct ReconnectPolicy {
    private var attempt = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return min(0.5 * pow(2.0, Double(attempt)), 8.0)
    }
    public mutating func reset() { attempt = 0 }
}

/// Rolling stream diagnostics for the UI.
public struct StreamStats {
    public var framesReceived = 0
    public var keyframesReceived = 0
    public var bytesReceived = 0
    public var decodeErrors = 0
    public var connectedSince: Date?
    private var fpsWindowStart = Date()
    private var fpsWindowFrames = 0
    public private(set) var fps: Double = 0

    public init() {}

    public mutating func recordFrame(bytes: Int, isKeyframe: Bool, now: Date = Date()) {
        framesReceived += 1
        bytesReceived += bytes
        if isKeyframe { keyframesReceived += 1 }
        fpsWindowFrames += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            fps = Double(fpsWindowFrames) / elapsed
            fpsWindowFrames = 0
            fpsWindowStart = now
        }
    }

    public var bitrateMbps: Double {
        guard let since = connectedSince else { return 0 }
        let seconds = max(1, Date().timeIntervalSince(since))
        return Double(bytesReceived) * 8 / seconds / 1_000_000
    }
}

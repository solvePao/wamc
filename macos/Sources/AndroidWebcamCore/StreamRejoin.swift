import CoreGraphics
import Foundation

/// Rejoin helpers: every pipeline restart on the phone must rejoin cleanly
/// instead of freezing WAMC / FaceTime on stale P-frames.
/// See shared/protocol/PROTOCOL.md "Restart and rejoin".
public enum StreamConfigDesc {
    public static func describe(codec: Int, width: Int, height: Int, fps: Int, rotation: Int) -> String {
        "\(codec):\(width)x\(height)@\(fps):\(rotation)"
    }
}

/// Throttled keyframe re-request after a CONFIG or transport start.
/// The decoder drops everything until the next keyframe, so a lost IDR
/// (restart race, hub drop) would freeze forever without this.
public final class KeyframeWatchdog {
    private let lock = NSLock()
    private var configAt: Date?
    private var keyframeSinceConfig = false
    private var lastRequestAt: Date?
    private var sentCount = 0

    public init() {}

    public func noteConfig(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        configAt = now
        keyframeSinceConfig = false
        lastRequestAt = nil
        sentCount = 0
    }

    public func noteKeyframe(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        keyframeSinceConfig = true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        configAt = nil
        keyframeSinceConfig = false
        lastRequestAt = nil
        sentCount = 0
    }

    public var pending: Bool {
        lock.lock(); defer { lock.unlock() }
        return configAt != nil && !keyframeSinceConfig
    }

    public var attempts: Int {
        lock.lock(); defer { lock.unlock() }
        return sentCount
    }

    public func timedOut(now: Date = Date(),
                         giveUpAfter: TimeInterval = 12.0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = configAt, !keyframeSinceConfig else { return false }
        return now.timeIntervalSince(since) >= giveUpAfter
    }

    /// True when a `requestKeyframe` should be sent now. Throttled, capped,
    /// and gives up after the window so a dead phone is not spammed.
    public func requestDue(now: Date = Date(),
                           throttle: TimeInterval = 1.0,
                           maxAttempts: Int = 8,
                           giveUpAfter: TimeInterval = 12.0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = configAt, !keyframeSinceConfig else { return false }
        guard sentCount < maxAttempts else { return false }
        guard now.timeIntervalSince(since) < giveUpAfter else { return false }
        if let last = lastRequestAt, now.timeIntervalSince(last) < throttle { return false }
        lastRequestAt = now
        sentCount += 1
        return true
    }
}

/// Fixed virtual-camera publish format. Meeting apps expect a stable size;
/// frames that arrive at another size are letterboxed into it, never
/// wrapped in a mismatched format description.
public enum BridgeFormat {
    public static let width = 1920
    public static let height = 1080

    public static func needsNormalization(srcWidth: Int, srcHeight: Int) -> Bool {
        srcWidth != width || srcHeight != height
    }

    /// Aspect-fit destination rect, centered. Empty source maps to `.zero`.
    public static func fitRect(srcWidth: Int, srcHeight: Int) -> CGRect {
        guard srcWidth > 0, srcHeight > 0 else { return .zero }
        let scale = min(CGFloat(width) / CGFloat(srcWidth), CGFloat(height) / CGFloat(srcHeight))
        let w = CGFloat(srcWidth) * scale
        let h = CGFloat(srcHeight) * scale
        return CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2,
                      width: w, height: h)
    }
}

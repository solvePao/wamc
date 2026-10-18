import Foundation

/// Read-only extension/app contract, shared by the signed camera target.
public struct CameraHealthSnapshot: Codable {
    public static let version = 1
    public static let selector: UInt32 = 0x77686c74 // 'whlt'
    public static let propertyName = "4cc_whlt_glob_0000"
    public static let liveSequenceAttachment = "WAMCLiveSequence"

    public let contractVersion: Int
    public let instanceID: String
    public let sinkSequence: UInt64
    public let sinkReceivedAt: TimeInterval
    public let sourceSequence: UInt64
    public let sourcePublishedAt: TimeInterval

    public init(instanceID: String, sinkSequence: UInt64, sinkReceivedAt: TimeInterval,
                sourceSequence: UInt64, sourcePublishedAt: TimeInterval) {
        contractVersion = Self.version
        self.instanceID = instanceID
        self.sinkSequence = sinkSequence
        self.sinkReceivedAt = sinkReceivedAt
        self.sourceSequence = sourceSequence
        self.sourcePublishedAt = sourcePublishedAt
    }

    public func hasFreshSink(at now: TimeInterval) -> Bool {
        sinkSequence > 0 && now >= sinkReceivedAt && now - sinkReceivedAt < 1
    }

    public func hasFreshSource(at now: TimeInterval) -> Bool {
        sourceSequence > 0 && now >= sourcePublishedAt && now - sourcePublishedAt < 1
    }
}

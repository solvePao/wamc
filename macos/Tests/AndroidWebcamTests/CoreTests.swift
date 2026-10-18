import XCTest
import CoreVideo
@testable import AndroidWebcamCore

final class CoreTests: XCTestCase {

    func testAnnexBToAVCC() {
        let annexB = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xEE])
        let avcc = H264.annexBToAVCC(annexB)
        XCTAssertEqual([UInt8](avcc), [0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 2, 0x68, 0xEE])
        XCTAssertEqual(H264.nalTypes(in: annexB), [7, 8])
    }

    func testKeyframeDetection() {
        XCTAssertTrue(H264.isKeyframeAccessUnit(Data([0, 0, 0, 1, 0x65, 0x88])))
        XCTAssertFalse(H264.isKeyframeAccessUnit(Data([0, 0, 0, 1, 0x41, 0x9A])))
    }

    func testSyncDetectionIsCodecAware() {
        let avcIdr = Data([0, 0, 0, 1, 0x65, 0x88])
        XCTAssertTrue(H264.isSyncAccessUnit(avcIdr, codec: .avc))
        XCTAssertFalse(H264.isSyncAccessUnit(avcIdr, codec: .hevc))
        // HEVC IDR_W_RADL (19): first byte 0x26 = (19 << 1).
        let hevcIdr = Data([0, 0, 0, 1, 0x26, 0x01])
        XCTAssertTrue(H264.isSyncAccessUnit(hevcIdr, codec: .hevc))
        XCTAssertEqual(H264.hevcNalTypes(in: hevcIdr), [19])
        // HEVC TRAIL (1): not random access.
        XCTAssertFalse(H264.isSyncAccessUnit(Data([0, 0, 0, 1, 0x02, 0x01]), codec: .hevc))
    }

    func testLatestWinsQueue() throws {
        let queue = LatestFrameQueue(capacity: 2)
        var buffers: [CVPixelBuffer] = []
        for _ in 0..<4 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
            buffers.append(try XCTUnwrap(pb))
        }
        buffers.forEach { queue.enqueue($0) }
        XCTAssertEqual(queue.enqueuedCount, 4)
        XCTAssertGreaterThanOrEqual(queue.droppedCount, 2)
        XCTAssertTrue(queue.dequeueLatest() === buffers.last)
        XCTAssertNil(queue.dequeueLatest())
    }

    func testRotationSwapsAxes() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &pb)
        let source = try XCTUnwrap(pb)
        let rotated = FrameRotation.rotate(source, quarterTurns: 1)
        XCTAssertEqual(CVPixelBufferGetWidth(rotated), 2)
        XCTAssertEqual(CVPixelBufferGetHeight(rotated), 4)
        XCTAssertTrue(FrameRotation.rotate(source, quarterTurns: 0) === source)
        let half = FrameRotation.rotate(source, quarterTurns: 2)
        XCTAssertEqual(CVPixelBufferGetWidth(half), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(half), 2)
    }

    func testReconnectBackoffCaps() {
        var policy = ReconnectPolicy()
        let delays = (0..<6).map { _ in policy.nextDelay() }
        XCTAssertEqual(delays, [0.5, 1, 2, 4, 8, 8])
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 0.5)
    }
}

final class AutoStartPolicyTests: XCTestCase {

    func testFreshPlugConnectsAndStarts() {
        var p = AutoStartPolicy()
        p.deviceListChanged(currentId: "RZCT40TFK9D")
        XCTAssertTrue(p.shouldConnect(devicePresent: true, connected: false, autoConnect: true))
        XCTAssertTrue(p.shouldAutoStart(autoStart: true))
    }

    func testNothingHappensWithoutDeviceOrWhenOff() {
        var p = AutoStartPolicy()
        XCTAssertFalse(p.shouldConnect(devicePresent: false, connected: false, autoConnect: true))
        p.deviceListChanged(currentId: "X")
        XCTAssertFalse(p.shouldConnect(devicePresent: true, connected: false, autoConnect: false))
        XCTAssertFalse(p.shouldAutoStart(autoStart: false))
    }

    func testExplicitStopHoldsUntilReplug() {
        var p = AutoStartPolicy()
        p.deviceListChanged(currentId: "X")
        p.didSendStart()
        XCTAssertFalse(p.shouldAutoStart(autoStart: true)) // already asked
        p.didSendStop()
        XCTAssertFalse(p.shouldConnect(devicePresent: true, connected: false, autoConnect: true))
        XCTAssertFalse(p.shouldAutoStart(autoStart: true))
        p.deviceListChanged(currentId: nil) // unplug clears the latch…
        p.deviceListChanged(currentId: "X") // …replug arrives fresh
        XCTAssertTrue(p.shouldConnect(devicePresent: true, connected: false, autoConnect: true))
        XCTAssertTrue(p.shouldAutoStart(autoStart: true))
    }

    func testTransientDropReasksWithoutLatch() {
        var p = AutoStartPolicy()
        p.deviceListChanged(currentId: "X")
        p.didSendStart()
        p.didDisconnect() // blip, not a decision
        XCTAssertTrue(p.shouldAutoStart(autoStart: true))
        p.manualDisconnect()
        XCTAssertFalse(p.shouldAutoStart(autoStart: true))
        XCTAssertFalse(p.shouldConnect(devicePresent: true, connected: false, autoConnect: true))
    }

    func testSameDeviceListDoesNotClearLatch() {
        var p = AutoStartPolicy()
        p.deviceListChanged(currentId: "X")
        p.didSendStop()
        p.deviceListChanged(currentId: "X")
        XCTAssertFalse(p.shouldAutoStart(autoStart: true))
    }
}

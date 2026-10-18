import XCTest
import CoreVideo
@testable import AndroidWebcamCore
@testable import AndroidWebcamProtocol

final class AdditionalCoreCoverageTests: XCTestCase {
    func testRotationKeepsOriginalWhenOutputAllocationFails() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let source = try XCTUnwrap(pixels)
        var requestedSize: [Int] = []
        let result = FrameRotation.rotate(source, quarterTurns: 1) { width, height in
            requestedSize = [width, height]
            return nil
        }
        XCTAssertTrue(result === source)
        XCTAssertEqual(requestedSize, [2, 4])
    }
    func testManualConnectClearsOnlyStopLatch() {
        var policy = AutoStartPolicy()
        policy.didSendStop()
        policy.manualConnect()
        XCTAssertFalse(policy.userStopped)
        XCTAssertFalse(policy.streamCommanded)
        XCTAssertTrue(policy.shouldConnect(devicePresent: true, connected: false, autoConnect: true))
    }

    func testDiscoveryUsesExplicitEmulatorValueBeforeModelHeuristics() throws {
        XCTAssertFalse(WamcDiscovery.isValidId(nil))
        for value in ["0", "1", "invalid"] {
            let device = try XCTUnwrap(DiscoveredDevice.parseTXT(
                ["id": "phone", "model": "sdk_gphone64_arm64", "emulator": value], instanceName: "Phone"))
            XCTAssertEqual(device.emulator, value == "invalid" ? nil : value == "1")
            XCTAssertEqual(device.isEmulator, value != "0")
        }
        let phone = DiscoveredDevice(id: "abcd", instanceName: "Bonjour", model: "", brand: "",
                                     sdk: nil, port: 27183, version: 2)
        XCTAssertEqual(phone.displayName, "Bonjour")
    }

    func testStatsPublishFpsAndBoundProcessingHistory() {
        var stats = StreamStats()
        stats.recordFrame(bytes: 100, isKeyframe: true, now: Date().addingTimeInterval(2))
        XCTAssertEqual(stats.framesReceived, 1)
        XCTAssertEqual(stats.keyframesReceived, 1)
        XCTAssertEqual(stats.bytesReceived, 100)
        XCTAssertGreaterThan(stats.fps, 0)
        XCTAssertLessThanOrEqual(stats.fps, 1)
        XCTAssertEqual(stats.bitrateMbps, 0)
        stats.connectedSince = Date()
        XCTAssertEqual(stats.bitrateMbps, 0.0008, accuracy: 0.000001)
        for sample in 0..<301 { stats.recordProcessing(ms: Double(sample)) }
        XCTAssertEqual(stats.processingSampleCount, 300)
        XCTAssertEqual(stats.processingP50Ms, 151)
        XCTAssertEqual(stats.processingP95Ms, 286)
    }

    func testConnectionEpochChangesOnlyOnConnectionAdvance() {
        let tracker = StreamFrameContextTracker()
        XCTAssertEqual(tracker.connectionEpoch, 0)
        XCTAssertEqual(tracker.advanceConnection(), 1)
        tracker.resetConfiguration()
        XCTAssertEqual(tracker.connectionEpoch, 1)
        XCTAssertEqual(tracker.advanceConnection(), 2)
    }

    func testEmptyAnnexBNalsDoNotBecomeFramesOrTypes() {
        let emptyNals = Data([0, 0, 0, 1, 0, 0, 0, 1])
        XCTAssertTrue(H264.nalTypes(in: emptyNals).isEmpty)
        XCTAssertTrue(H264.hevcNalTypes(in: emptyNals).isEmpty)
        XCTAssertTrue(H264.annexBToAVCC(emptyNals).isEmpty)
    }

    func testEveryTruncatedConfigurationIsRejected() {
        let legacy = WireProtocol.encodeConfig(sps: Data([0x67]), pps: Data([0x68]),
                                               width: 1920, height: 1080, fps: 30)
        for end in 0..<legacy.count {
            XCTAssertNil(WireProtocol.decodeConfig(legacy.prefix(end)), "legacy prefix \(end)")
        }
        let negotiated = WireProtocol.encodeConfigV2(codec: WireProtocol.codecAVC,
            paramSets: [Data([0x67]), Data([0x68])], width: 1920, height: 1080, fps: 30)
        for end in 0..<negotiated.count {
            XCTAssertNil(WireProtocol.decodeConfigV2(negotiated.prefix(end)), "negotiated prefix \(end)")
        }
    }

    func testParserRejectsOversizedPayloadAndFindsNextFrame() {
        var oversized = WireProtocol.encode(type: 1, flags: 0, ptsUs: 0, payload: Data())
        oversized.replaceSubrange(16..<20, with: [0, 0x80, 0, 1])
        let frame = WireProtocol.encode(type: 4, flags: 0, ptsUs: 9, payload: Data([1]))
        let parser = FrameParser()
        XCTAssertTrue(parser.feed(oversized + frame).isEmpty)
        XCTAssertEqual(parser.feed(Data()), [WireProtocol.Frame(type: 4, flags: 0, ptsUs: 9, payload: Data([1]))])
    }

    func testParserRetainsPartialMagicAcrossLongGarbage() {
        let parser = FrameParser()
        XCTAssertTrue(parser.feed(Data(repeating: 0xff, count: 128)).isEmpty)
        let bytes = WireProtocol.encode(type: 1, flags: 1, ptsUs: -42, payload: Data([7]))
        XCTAssertTrue(parser.feed(bytes.prefix(3)).isEmpty)
        let frames = parser.feed(bytes.dropFirst(3))
        XCTAssertEqual(frames.first?.ptsUs, -42)
        XCTAssertEqual(frames.first?.payload, Data([7]))
        XCTAssertEqual(frames.first?.isKeyframe, true)
    }
}

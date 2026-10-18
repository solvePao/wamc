import XCTest
@testable import AndroidWebcamProtocol

final class WireProtocolTests: XCTestCase {

    func testGoldenVectorMatchesSpec() {
        let payload = Data([0, 0, 0, 1, 0x65, 0x88])
        let bytes = WireProtocol.encode(type: 1, flags: 1, ptsUs: 1000, payload: payload)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "415743310101000000000000000003e800000006000000016588")
    }

    func testParserHandlesSplitAndGarbage() {
        let payload = Data([0, 0, 0, 1, 0x67, 0x42])
        let bytes = WireProtocol.encode(type: 1, flags: 1, ptsUs: 42, payload: payload)
        let parser = FrameParser()
        XCTAssertTrue(parser.feed(Data([0xFF, 0x00])).isEmpty)
        let frames = parser.feed(bytes.prefix(7)) + parser.feed(bytes.suffix(from: 7))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.ptsUs, 42)
        XCTAssertEqual(frames.first?.payload, payload)
    }

    func testConfigRoundTrip() {
        let sps = Data([0x67, 0x64, 0x00]); let pps = Data([0x68, 0xEE])
        let cfg = WireProtocol.decodeConfig(
            WireProtocol.encodeConfig(sps: sps, pps: pps, width: 1920, height: 1080, fps: 30, rotation: 1))
        XCTAssertEqual(cfg?.sps, sps); XCTAssertEqual(cfg?.pps, pps)
        XCTAssertEqual(cfg?.width, 1920); XCTAssertEqual(cfg?.height, 1080)
        XCTAssertEqual(cfg?.fps, 30)
        XCTAssertEqual(cfg?.rotation, 1)
    }

    func testControlRoundTrip() {
        let decoded = WireProtocol.decodeControl(
            WireProtocol.encodeControl([("cmd", "start"), ("facing", "back"), ("width", "1920")]))
        XCTAssertEqual(decoded, ["cmd": "start", "facing": "back", "width": "1920"])
    }

    func testConfigV2AvcRoundTrip() {
        let sps = Data([0x67, 0x64, 0x00]); let pps = Data([0x68, 0xEE])
        let cfg = WireProtocol.decodeConfigV2(
            WireProtocol.encodeConfigV2(codec: 0, paramSets: [sps, pps],
                                        width: 1920, height: 1080, fps: 30))
        XCTAssertEqual(cfg?.codec, 0)
        XCTAssertEqual(cfg?.paramSets, [sps, pps])
        XCTAssertEqual(cfg?.width, 1920); XCTAssertEqual(cfg?.height, 1080)
        XCTAssertEqual(cfg?.fps, 30); XCTAssertEqual(cfg?.rotation, 0)
    }

    func testConfigV2HevcRoundTripKeepsVpsSpsPpsOrder() {
        let vps = Data([0x40, 0x01]); let sps = Data([0x42, 0x01]); let pps = Data([0x44, 0x01])
        let cfg = WireProtocol.decodeConfigV2(
            WireProtocol.encodeConfigV2(codec: 1, paramSets: [vps, sps, pps],
                                        width: 3840, height: 2160, fps: 30))
        XCTAssertEqual(cfg?.codec, 1)
        XCTAssertEqual(cfg?.paramSets, [vps, sps, pps])
        XCTAssertEqual(cfg?.width, 3840); XCTAssertEqual(cfg?.height, 2160)
    }

    func testConfigV2RejectsUnknownCodec() {
        var payload = WireProtocol.encodeConfigV2(codec: 0, paramSets: [Data([0x67])],
                                                  width: 320, height: 240, fps: 30)
        payload[0] = 9
        XCTAssertNil(WireProtocol.decodeConfigV2(payload))
    }

    func testControlCarriesNegotiationKeys() {
        let decoded = WireProtocol.decodeControl(
            WireProtocol.encodeControl([("cmd", "start"), ("codec", "auto"),
                                        ("quality", "best"), ("configV2", "1")]))
        XCTAssertEqual(decoded, ["cmd": "start", "codec": "auto",
                                 "quality": "best", "configV2": "1"])
    }
}

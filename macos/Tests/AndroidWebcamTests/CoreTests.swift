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

    func testProcessingPercentiles() {
        var stats = StreamStats()
        XCTAssertEqual(stats.processingP95Ms, 0)
        for ms in stride(from: 10.0, through: 100.0, by: 10.0) {
            stats.recordProcessing(ms: ms)
        }
        XCTAssertEqual(stats.processingSampleCount, 10)
        XCTAssertEqual(stats.processingP50Ms, 60, accuracy: 0.001)
        XCTAssertEqual(stats.processingP95Ms, 100, accuracy: 0.001)
        stats.recordProcessing(ms: -1)
        stats.recordProcessing(ms: 99_999)
        XCTAssertEqual(stats.processingSampleCount, 10)
    }

    func testReconnectBackoffCaps() {
        var policy = ReconnectPolicy()
        let delays = (0..<6).map { _ in policy.nextDelay() }
        XCTAssertEqual(delays, [0.5, 1, 2, 4, 8, 8])
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 0.5)
    }
}

final class DiscoveryTests: XCTestCase {
    func testParseTXTBuildsDevice() {
        let d = DiscoveredDevice.parseTXT(
            ["v": "2", "id": "550e8400-e29b", "model": "SM-E236B",
             "brand": "samsung", "sdk": "34", "port": "27183"],
            instanceName: "WAMC-SM-E236B-550e")
        XCTAssertEqual(d?.id, "550e8400-e29b")
        XCTAssertEqual(d?.model, "SM-E236B")
        XCTAssertEqual(d?.sdk, 34)
        XCTAssertEqual(d?.port, 27183)
        XCTAssertEqual(d?.version, 2)
        XCTAssertEqual(d?.displayName, "SM-E236B · 550e")
    }

    func testParseTXTRejectsMissingOrBadId() {
        XCTAssertNil(DiscoveredDevice.parseTXT(["model": "X"], instanceName: "WAMC-X"))
        XCTAssertNil(DiscoveredDevice.parseTXT(["id": "has space"], instanceName: "WAMC-X"))
        XCTAssertNil(DiscoveredDevice.parseTXT(["id": "ok-1", "port": "99999"], instanceName: "WAMC-X"))
    }

    func testParseTXTDefaultsPortAndVersion() {
        let d = DiscoveredDevice.parseTXT(["id": "dev-1"], instanceName: "WAMC-dev")
        XCTAssertEqual(d?.port, 27183)
        XCTAssertEqual(d?.version, 1)
    }

    func testTrustStore() {
        var t = TrustedDevices()
        XCTAssertFalse(t.isTrusted("a"))
        t.trust("a")
        XCTAssertTrue(t.isTrusted("a"))
        t.untrust("a")
        XCTAssertFalse(t.isTrusted("a"))
    }

    func testShortId() {
        XCTAssertEqual(WamcDiscovery.shortId("A1B2C3-zz"), "a1b2")
        XCTAssertEqual(WamcDiscovery.shortId("---"), "0000")
    }
}

final class ConnectionPolicyTests: XCTestCase {
    private func device(id: String = "dev-1") -> DiscoveredDevice {
        DiscoveredDevice(id: id, instanceName: "WAMC-X", model: "SM-E236B",
                         brand: "samsung", sdk: 34, port: 27183, version: 2)
    }

    func testUSBPreferredOverWifi() {
        let p = ConnectionPolicy()
        XCTAssertEqual(p.preferredTransport(usbPresent: true, trustedWifiAvailable: true), .usb)
        XCTAssertEqual(p.preferredTransport(usbPresent: false, trustedWifiAvailable: true), .wifi)
        XCTAssertNil(p.preferredTransport(usbPresent: false, trustedWifiAvailable: false))
    }

    func testWifiAutoConnectRequiresTrustAndNoLatch() {
        let p = ConnectionPolicy()
        XCTAssertTrue(p.shouldAutoConnectWifi(device: device(), trusted: true,
                                              active: nil, autoConnect: true, userStopped: false))
        XCTAssertFalse(p.shouldAutoConnectWifi(device: device(), trusted: false,
                                               active: nil, autoConnect: true, userStopped: false))
        XCTAssertFalse(p.shouldAutoConnectWifi(device: device(), trusted: true,
                                               active: nil, autoConnect: true, userStopped: true))
        XCTAssertFalse(p.shouldAutoConnectWifi(device: device(), trusted: true,
                                               active: .usb, autoConnect: true, userStopped: false))
    }

    func testSwitchAndFallback() {
        let p = ConnectionPolicy()
        XCTAssertTrue(p.shouldSwitchToUSB(active: .wifi, usbPresent: true))
        XCTAssertFalse(p.shouldSwitchToUSB(active: .usb, usbPresent: true))
        XCTAssertTrue(p.shouldFallBackToWifi(active: nil, usbPresent: false,
                                             trustedWifiAvailable: true, autoConnect: true, userStopped: false))
        XCTAssertFalse(p.shouldFallBackToWifi(active: nil, usbPresent: true,
                                              trustedWifiAvailable: true, autoConnect: true, userStopped: false))
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

final class AdbDeviceListTests: XCTestCase {
    // Modern `adb devices -l` pads columns with spaces (older builds use
    // tabs); both must parse or no phone is ever enumerated.
    func testParsesSpacePaddedColumns() {
        let out = "List of devices attached\nRZCT40TFK9D            device usb:17825792X product:m23xqdd model:SM_E236B device:m23xq transport_id:19\n"
        let parsed = AdbDeviceList.parse(out)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.serial, "RZCT40TFK9D")
        XCTAssertEqual(parsed.first?.state, "device")
        XCTAssertEqual(parsed.first?.model, "SM E236B")
    }

    func testParsesTabColumnsAndSkipsOffline() {
        let out = "List of devices attached\nABC123\toffline\n\n"
        let parsed = AdbDeviceList.parse(out)
        XCTAssertEqual(parsed.first?.serial, "ABC123")
        XCTAssertEqual(parsed.first?.state, "offline")
    }
}

final class StreamRejoinTests: XCTestCase {
    func testConfigDescDistinguishesCodec() {
        let avc = StreamConfigDesc.describe(codec: 0, width: 1920, height: 1080, fps: 30, rotation: 1)
        let hevc = StreamConfigDesc.describe(codec: 1, width: 1920, height: 1080, fps: 30, rotation: 1)
        XCTAssertNotEqual(avc, hevc)
        XCTAssertEqual(avc, StreamConfigDesc.describe(codec: 0, width: 1920, height: 1080, fps: 30, rotation: 1))
    }

    func testWatchdogFiresOnceThenThrottles() {
        let w = KeyframeWatchdog()
        XCTAssertFalse(w.requestDue())
        let t0 = Date()
        w.noteConfig(now: t0)
        XCTAssertTrue(w.pending)
        XCTAssertTrue(w.requestDue(now: t0))
        XCTAssertEqual(w.attempts, 1)
        XCTAssertFalse(w.requestDue(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(w.requestDue(now: t0.addingTimeInterval(1.0)))
        w.noteKeyframe(now: t0.addingTimeInterval(1.5))
        XCTAssertFalse(w.pending)
        XCTAssertFalse(w.requestDue(now: t0.addingTimeInterval(2.0)))
    }

    func testWatchdogCapsAttemptsAndGivesUp() {
        let w = KeyframeWatchdog()
        let t0 = Date()
        w.noteConfig(now: t0)
        var fires = 0
        for i in 0..<20 {
            if w.requestDue(now: t0.addingTimeInterval(Double(i)), throttle: 1.0,
                             maxAttempts: 3, giveUpAfter: 60) { fires += 1 }
        }
        XCTAssertEqual(fires, 3)
        XCTAssertFalse(w.requestDue(now: t0.addingTimeInterval(120)))
        XCTAssertTrue(w.timedOut(now: t0.addingTimeInterval(12), giveUpAfter: 12))
        w.noteKeyframe(now: t0.addingTimeInterval(13))
        XCTAssertFalse(w.timedOut(now: t0.addingTimeInterval(13), giveUpAfter: 12))
    }

    func testBridgeFormatFit() {
        XCTAssertFalse(BridgeFormat.needsNormalization(srcWidth: 1920, srcHeight: 1080))
        XCTAssertTrue(BridgeFormat.needsNormalization(srcWidth: 1280, srcHeight: 720))
        let fit = BridgeFormat.fitRect(srcWidth: 1280, srcHeight: 720)
        XCTAssertEqual(fit.width, 1920, accuracy: 0.001)
        XCTAssertEqual(fit.height, 1080, accuracy: 0.001)
        let portrait = BridgeFormat.fitRect(srcWidth: 720, srcHeight: 1280)
        XCTAssertEqual(portrait.height, 1080, accuracy: 0.001)
        XCTAssertLessThan(portrait.width, 1920)
        XCTAssertEqual(portrait.minX, (1920 - portrait.width) / 2, accuracy: 0.001)
        XCTAssertEqual(BridgeFormat.fitRect(srcWidth: 0, srcHeight: 0), .zero)
    }
}

final class PublishGateTests: XCTestCase {
    // Regression test for the menu-bar flicker: stats mutate ~30×/s while
    // streaming, and every SwiftUI publish rebuilds an open MenuBarExtra
    // menu (flicker + swallowed clicks on Quality). The gate must hold the
    // publish rate to its interval.

    func testFirstFirePassesThenThrottlesWithinInterval() {
        var gate = PublishGate(interval: 1.0)
        let t0 = Date()
        XCTAssertTrue(gate.shouldFire(now: t0))
        XCTAssertFalse(gate.shouldFire(now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(gate.shouldFire(now: t0.addingTimeInterval(0.999)))
        XCTAssertTrue(gate.shouldFire(now: t0.addingTimeInterval(1.0)))
        XCTAssertFalse(gate.shouldFire(now: t0.addingTimeInterval(1.5)))
    }

    func testThirtyFpsStreamPublishesAtMostOncePerSecond() {
        var gate = PublishGate(interval: 1.0)
        var fires = 0
        var now = Date()
        for _ in 0 ..< 90 { // 3 s of frames at 30 fps
            if gate.shouldFire(now: now) { fires += 1 }
            now = now.addingTimeInterval(1.0 / 30.0)
        }
        XCTAssertLessThanOrEqual(fires, 4) // vs 90 unthrottled
        XCTAssertGreaterThanOrEqual(fires, 2)
    }

    func testFpsValueIsStableWithinOneSecondWindow() {
        // Supporting fact the throttle relies on: frames arriving inside
        // the same 1 s window do not change the visible fps value, so
        // publishing per frame is pure menu churn.
        var stats = StreamStats()
        let t0 = Date()
        for i in 0 ..< 30 {
            stats.recordFrame(bytes: 1000, isKeyframe: i == 0,
                              now: t0.addingTimeInterval(Double(i) / 30.0))
        }
        XCTAssertEqual(stats.fps, 0)
    }
}

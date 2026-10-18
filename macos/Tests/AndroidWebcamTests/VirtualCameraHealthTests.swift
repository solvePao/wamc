import XCTest
import AVFoundation
import CoreMedia
import CoreMediaIO
import AndroidWebcamCore
@testable import AndroidWebcamAppRuntime

final class VirtualCameraHealthTests: XCTestCase {
    func testUsageDescriptionsCoverKnownAndUnknownStatus() {
        XCTAssertEqual(VirtualCameraHealth(inUse: true).usageText, "In use by another app")
        XCTAssertEqual(VirtualCameraHealth(inUse: false).usageText, "Not currently used by another app")
        XCTAssertEqual(VirtualCameraHealth().usageText, "Usage unavailable")
    }

    @MainActor
    func testMonitorRejectsStaleResultsAndRetriesCurrentInput() async throws {
        let probe = StubHealthProbe()
        let monitor = VirtualCameraHealthMonitor(probe: probe)
        monitor.checkAgain()
        XCTAssertTrue(probe.updates.isEmpty)
        monitor.update(feedLive: true, bridgeAvailable: true, extensionEnabled: true)
        monitor.update(feedLive: true, bridgeAvailable: true, extensionEnabled: true)
        XCTAssertEqual(probe.updates.count, 1)
        probe.onChange?(1, VirtualCameraHealth(output: .ready, detail: "ready", inUse: true))
        try await waitUntil("Current probe result reaches UI") { monitor.health.output == .ready }
        monitor.update(feedLive: false, bridgeAvailable: true, extensionEnabled: true)
        XCTAssertEqual(monitor.health.output, .waiting)
        probe.onChange?(1, VirtualCameraHealth(output: .ready, detail: "stale"))
        await drainMainQueue()
        XCTAssertEqual(monitor.health.output, .waiting)
        probe.onChange?(2, VirtualCameraHealth(output: .unavailable, detail: "no feed"))
        try await waitUntil("New generation reaches UI") { monitor.health.output == .unavailable }
        monitor.checkAgain()
        XCTAssertEqual(probe.updates.map(\.1), [1, 2, 3])
    }

    func testPrerequisitesAndAuthorizationPreventReadback() {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.start(feedLive: false)
        XCTAssertEqual(fixture.latest.output, .waiting)
        fixture.start(extensionEnabled: false)
        XCTAssertTrue(fixture.latest.detail.contains("Enable WAMC"))
        fixture.start(bridgeAvailable: false)
        XCTAssertTrue(fixture.latest.detail.contains("video input"))
        fixture.authorization = .notDetermined
        fixture.start()
        XCTAssertTrue(fixture.latest.detail.contains("Allow Camera Access"))
        fixture.authorization = .denied
        fixture.start()
        XCTAssertTrue(fixture.latest.detail.contains("blocked"))
        XCTAssertEqual(fixture.capture.starts, 0)
    }

    func testMissingDeviceAndMissingSnapshotRemainUnavailable() {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.discovered = nil
        fixture.start()
        XCTAssertTrue(fixture.latest.detail.contains("unavailable to macOS apps"))
        fixture.discovered = fixture.device
        fixture.snapshot = nil
        fixture.refresh()
        XCTAssertTrue(fixture.latest.detail.contains("update WAMC"))
        fixture.device.isConnected = false
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .unavailable)
        XCTAssertEqual(fixture.capture.starts, 0)
    }

    func testStaleSinkStopsReadbackAndResumesOnlyWithFreshDelivery() {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.snapshot = fixture.makeSnapshot(time: 98)
        fixture.start()
        XCTAssertEqual(fixture.latest.output, .failed)
        XCTAssertTrue(fixture.latest.detail.contains("not receiving fresh"))
        fixture.snapshot = fixture.makeSnapshot()
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .checking)
        XCTAssertEqual(fixture.capture.starts, 1)
        fixture.snapshot = fixture.makeSnapshot(time: 98)
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .failed)
        XCTAssertEqual(fixture.capture.stops, 1)
    }

    func testReadbackFailuresPublishSpecificErrors() {
        for failure in ["input", "output", "creation"] {
            let fixture = HealthProbeFixture()
            defer { fixture.stop() }
            fixture.capture.canAddInput = failure != "input"
            fixture.capture.canAddOutput = failure != "output"
            if failure == "creation" { fixture.captureError = NSError(domain: "CameraTest", code: 7) }
            fixture.start()
            XCTAssertEqual(fixture.latest.output, .failed)
            XCTAssertEqual(fixture.capture.starts, 0)
            XCTAssertTrue(fixture.latest.detail.contains(failure == "output" ? "configure" : "open"))
        }
    }

    func testReadbackDeadlineDoesNotRetryUntilExplicitNewGeneration() {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.start()
        fixture.now = 104.9
        fixture.snapshot = fixture.makeSnapshot()
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .checking)
        fixture.now = 105
        fixture.snapshot = fixture.makeSnapshot()
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .failed)
        XCTAssertTrue(fixture.latest.detail.contains("five seconds"))
        fixture.refresh()
        XCTAssertEqual(fixture.capture.starts, 1)
        fixture.start()
        XCTAssertEqual(fixture.capture.starts, 2)
    }

    func testThreeAdvancingFreshFramesVerifyReadbackAndRetainReadyState() throws {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.start()
        let wrongOutput = AVCaptureVideoDataOutput()
        let wrongSample = try makeSample(pts: .zero)
        fixture.queue.sync { fixture.probe.processSample(wrongSample, output: wrongOutput) }
        let connection = AVCaptureConnection(inputPorts: [], output: fixture.capture.output)
        for sequence in 11...13 {
            fixture.snapshot = fixture.makeSnapshot(sequence: UInt64(sequence))
            let sample = try makeSample(pts: CMTime(value: Int64(sequence), timescale: 30))
            fixture.queue.sync {
                fixture.probe.captureOutput(fixture.capture.output, didOutput: sample, from: connection)
            }
            XCTAssertEqual(fixture.latest.output, sequence < 13 ? .checking : .ready)
        }
        XCTAssertEqual(fixture.capture.stops, 1)
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .ready)
        fixture.device.isInUseByAnotherApplication = true
        fixture.device.changed?()
        XCTAssertEqual(fixture.latest.inUse, true)
    }

    func testReadbackRejectsInvalidTimeNonAdvancingSequenceAndRestartedExtension() throws {
        let fixture = HealthProbeFixture()
        defer { fixture.stop() }
        fixture.start()
        fixture.snapshot = fixture.makeSnapshot(sequence: 11)
        for pts in [CMTime.invalid, CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 30)] {
            let sample = try makeSample(pts: pts)
            fixture.queue.sync { fixture.probe.processSample(sample, output: fixture.capture.output) }
        }
        fixture.snapshot = fixture.makeSnapshot(instance: "replacement", sequence: 12)
        let sample = try makeSample(pts: CMTime(value: 2, timescale: 30))
        fixture.queue.sync { fixture.probe.processSample(sample, output: fixture.capture.output) }
        XCTAssertEqual(fixture.latest.output, .checking)
        fixture.refresh()
        XCTAssertEqual(fixture.capture.starts, 2, "New extension instance requires a new readback")
        fixture.authorization = .denied
        fixture.refresh()
        XCTAssertEqual(fixture.latest.output, .unavailable)
    }

    func testSnapshotQueryRejectsInvalidContractAndFindsMatchingDevice() throws {
        let snapshot = CameraHealthSnapshot(instanceID: "instance", sinkSequence: 1, sinkReceivedAt: 2,
                                            sourceSequence: 3, sourcePublishedAt: 4)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let reader = HealthPropertyReader(ids: [1, 2, 3, 4, 5], strings: [
            2: [UInt32(kCMIODevicePropertyDeviceUID): "other"],
            3: [UInt32(kCMIODevicePropertyDeviceUID): VirtualCameraDevice.uid, CameraHealthSnapshot.selector: "invalid"],
            4: [UInt32(kCMIODevicePropertyDeviceUID): VirtualCameraDevice.uid,
                CameraHealthSnapshot.selector: json.replacingOccurrences(of: "\"contractVersion\":1", with: "\"contractVersion\":99")],
            5: [UInt32(kCMIODevicePropertyDeviceUID): VirtualCameraDevice.uid, CameraHealthSnapshot.selector: json],
        ])
        XCTAssertEqual(CameraHealthSnapshotQuery(reader: reader).read()?.instanceID, "instance")
        XCTAssertNil(CameraHealthSnapshotQuery(reader: HealthPropertyReader(ids: [], strings: [:])).read())
        XCTAssertNil(CameraHealthSnapshotQuery(reader: HealthPropertyReader(ids: nil, strings: [:])).read())
        XCTAssertThrowsError(try SystemCameraReadbackSession(device: TestCameraDevice()))
    }

    func testDefaultProbeRefreshUsesSystemDiscoveryWithoutStartingCamera() async {
        let probe = VirtualCameraProbe()
        let refreshed = expectation(description: "system probe reports idle state")
        refreshed.expectedFulfillmentCount = 2
        refreshed.assertForOverFulfill = false
        probe.onChange = { _, state in if state.output == .waiting { refreshed.fulfill() } }
        probe.update(.init(feedLive: false, bridgeAvailable: false, extensionEnabled: false), revision: 1)
        await fulfillment(of: [refreshed], timeout: 2)
    }

    func testProbeUsesHostClockAndStopsReadbackWhenReleased() {
        let queue = DispatchQueue(label: "wamc.host-clock-test")
        let device = TestCameraDevice()
        let capture = TestReadbackSession()
        var probe: VirtualCameraProbe? = VirtualCameraProbe(queue: queue, authorization: { .authorized },
            discoverDevice: { device }, readSnapshot: {
                let now = ProcessInfo.processInfo.systemUptime
                return CameraHealthSnapshot(instanceID: "instance", sinkSequence: 1, sinkReceivedAt: now,
                    sourceSequence: 1, sourcePublishedAt: now)
            }, makeCapture: { _ in capture }, automaticRefresh: false)
        probe?.update(.init(feedLive: true, bridgeAvailable: true, extensionEnabled: true), revision: 1)
        queue.sync { XCTAssertEqual(capture.starts, 1) }
        probe = nil
        queue.sync { XCTAssertEqual(capture.stops, 1) }
    }

    func testDefaultReadbackFactoryRejectsNonNativeDevice() {
        let queue = DispatchQueue(label: "wamc.default-readback-test")
        let device = TestCameraDevice()
        var latest = VirtualCameraHealth()
        let probe = VirtualCameraProbe(queue: queue, authorization: { .authorized }, discoverDevice: { device },
            readSnapshot: { CameraHealthSnapshot(instanceID: "instance", sinkSequence: 1, sinkReceivedAt: 100,
                sourceSequence: 1, sourcePublishedAt: 100) }, clock: { 100 }, automaticRefresh: false)
        probe.onChange = { _, health in latest = health }
        probe.update(.init(feedLive: true, bridgeAvailable: true, extensionEnabled: true), revision: 1)
        queue.sync {
            XCTAssertEqual(latest.output, .failed)
            XCTAssertTrue(latest.detail.contains("Camera device is unavailable"))
        }
    }

    private func makeSample(pts: CMTime) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

private final class StubHealthProbe: VirtualCameraProbing {
    var onChange: ((UInt64, VirtualCameraHealth) -> Void)?
    var updates: [(VirtualCameraProbe.Input, UInt64)] = []
    func update(_ input: VirtualCameraProbe.Input, revision: UInt64) { updates.append((input, revision)) }
}

private final class HealthProbeFixture {
    let queue = DispatchQueue(label: "wamc.health-fixture")
    let device = TestCameraDevice()
    let capture = TestReadbackSession()
    var authorization = AVAuthorizationStatus.authorized
    var now: TimeInterval = 100
    var discovered: TestCameraDevice?
    var snapshot: CameraHealthSnapshot?
    var captureError: Error?
    private var states: [VirtualCameraHealth] = []
    private var revision: UInt64 = 0
    lazy var probe = VirtualCameraProbe(queue: queue, authorization: { [unowned self] in authorization },
        discoverDevice: { [unowned self] in discovered }, readSnapshot: { [unowned self] in snapshot },
        clock: { [unowned self] in now }, makeCapture: { [unowned self] _ in
            if let captureError { throw captureError }
            return capture
        }, automaticRefresh: false)
    var latest: VirtualCameraHealth { queue.sync { states.last ?? VirtualCameraHealth() } }
    init() {
        discovered = device
        snapshot = makeSnapshot()
        probe.onChange = { [unowned self] _, state in states.append(state) }
    }
    func makeSnapshot(instance: String = "instance", sequence: UInt64 = 10,
                      time: TimeInterval? = nil) -> CameraHealthSnapshot {
        CameraHealthSnapshot(instanceID: instance, sinkSequence: sequence, sinkReceivedAt: time ?? now,
                             sourceSequence: sequence, sourcePublishedAt: time ?? now)
    }
    func start(feedLive: Bool = true, bridgeAvailable: Bool = true, extensionEnabled: Bool = true) {
        revision += 1
        probe.update(.init(feedLive: feedLive, bridgeAvailable: bridgeAvailable, extensionEnabled: extensionEnabled),
                     revision: revision)
        queue.sync {}
    }
    func refresh() { queue.sync { probe.refresh() } }
    func stop() { start(feedLive: false); queue.sync {} }
}

private final class TestCameraDevice: CameraProbeDevice {
    var uniqueID = VirtualCameraDevice.uid
    var isConnected = true
    var isInUseByAnotherApplication = false
    var changed: (() -> Void)?
    func observeUsage(_ changed: @escaping () -> Void) -> CameraUsageObserving? {
        self.changed = changed
        changed()
        return TestUsageObservation()
    }
}

private struct TestUsageObservation: CameraUsageObserving {
    func invalidate() {}
}

private final class TestReadbackSession: CameraReadbackSession {
    let output = AVCaptureVideoDataOutput()
    var canAddInput = true
    var canAddOutput = true
    var starts = 0
    var stops = 0
    func addInput() {}
    func addOutput() {}
    func startRunning() { starts += 1 }
    func stopRunning() { stops += 1 }
}

private struct HealthPropertyReader: CoreMediaIOPropertyReading {
    let ids: [UInt32]?
    let strings: [UInt32: [UInt32: String]]
    func objects(for object: UInt32, selector: UInt32) throws -> [UInt32] {
        guard let ids else { throw NSError(domain: "HealthQuery", code: 1) }
        return ids
    }
    func string(for object: UInt32, selector: UInt32) throws -> String? { strings[object]?[selector] }
}

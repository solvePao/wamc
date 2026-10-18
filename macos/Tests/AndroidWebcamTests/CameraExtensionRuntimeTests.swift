import CoreVideo
import CoreMedia
import CoreMediaIO
import XCTest
@testable import CameraExtensionRuntime

final class CameraExtensionRuntimeTests: XCTestCase {
    func testSharedFrameReturnsLatestStoredBuffer() throws {
        let frame = try makePixelBuffer(width: 4, height: 4)

        SharedFrame.shared.store(frame)

        XCTAssertTrue(SharedFrame.shared.latest() === frame)
        XCTAssertTrue(SharedFrame.shared.latestFresh(within: 1) === frame)
    }

    func testSharedFrameExpiresStaleBufferUsingInjectedClock() throws {
        var now = Date(timeIntervalSince1970: 100)
        let shared = SharedFrame(now: { now })
        let frame = try makePixelBuffer(width: 4, height: 4)

        XCTAssertNil(shared.latest())
        shared.store(frame)
        XCTAssertTrue(shared.latestFresh(within: 1) === frame)
        now.addTimeInterval(2)
        XCTAssertNil(shared.latestFresh(within: 1))
        XCTAssertTrue(shared.latest() === frame)
    }

    func testProductionFrameProviderBuildsSampleFromFreshOrPlaceholderFrame() throws {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var date = Date(timeIntervalSince1970: 100)
        let sharedFrame = SharedFrame(now: { date })
        let provider = SharedCameraFrameProvider(sharedFrame: sharedFrame)
        sharedFrame.store(try makePixelBuffer(width: 4, height: 4))
        let freshSample = try XCTUnwrap(provider.sample(format: nil, hostTime: now))
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(freshSample))
        date.addTimeInterval(2)
        let waitingSample = try XCTUnwrap(provider.sample(format: nil, hostTime: now))
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(waitingSample))
    }

    func testStreamSourcesExposeFormatsAndProperties() throws {
        let source = SourceStreamSource(localizedName: "test")
        let sink = SinkStreamSource(localizedName: "test")

        XCTAssertEqual(source.formats.count, 1)
        XCTAssertEqual(sink.formats.count, 1)
        XCTAssertNoThrow(try source.streamProperties(forProperties: source.availableProperties))
        XCTAssertNoThrow(try sink.streamProperties(forProperties: sink.availableProperties))

        try source.startStream()
        try source.startStream()
        try source.stopStream()
        try source.stopStream()
        try source.stopStream()
        try sink.startStream()
        try sink.startStream()
        try sink.stopStream()
        try sink.stopStream()
    }

    func testSourceStreamPublishesFramesAndStopsAfterLastClient() throws {
        let sample = try makeSample(from: makePixelBuffer(width: 4, height: 4))
        let provider = FakeCameraFrameProvider(sample: sample)
        let publisher = FakeExtensionSamplePublisher {}
        let timer = ManualCameraStreamTimer()
        let source = SourceStreamSource(localizedName: "test", frameProvider: provider,
                                        publisher: publisher, timer: timer)

        try source.startStream()
        try source.startStream()
        timer.tick()
        XCTAssertEqual(timer.startCount, 1)
        XCTAssertEqual(publisher.sendCount, 1)
        try source.stopStream()
        timer.tick()
        XCTAssertEqual(publisher.sendCount, 2, "One client still consumes frames")

        try source.stopStream()
        timer.tick()
        XCTAssertEqual(timer.stopCount, 1)
        XCTAssertEqual(publisher.sendCount, 2, "The final client cancels frame pacing")
    }

    func testSourceStreamSkipsPublishingWhenFrameProviderHasNoSample() throws {
        let provider = EmptyCameraFrameProvider()
        let publisher = FakeExtensionSamplePublisher {}
        let timer = ManualCameraStreamTimer()
        let source = SourceStreamSource(localizedName: "test", frameProvider: provider,
                                        publisher: publisher, timer: timer)

        try source.startStream()
        timer.tick()
        try source.stopStream()

        XCTAssertEqual(provider.sampleCount, 1)
        XCTAssertEqual(publisher.sendCount, 0)
    }

    func testProductionTimerPublishesAFrameWithoutWaitingForAnArbitraryDelay() async throws {
        let sample = try makeSample(from: makePixelBuffer(width: 4, height: 4))
        let sent = expectation(description: "production timer publishes a frame")
        sent.assertForOverFulfill = false
        let source = SourceStreamSource(localizedName: "test",
            frameProvider: FakeCameraFrameProvider(sample: sample),
            publisher: FakeExtensionSamplePublisher { sent.fulfill() })
        try source.startStream()
        defer { try? source.stopStream() }
        await fulfillment(of: [sent], timeout: 1)
    }

    func testSinkStreamAcceptsSamplesOnlyWhileStreaming() throws {
        let sink = SinkStreamSource(localizedName: "test")
        let first = try makePixelBuffer(width: 4, height: 4)
        let second = try makePixelBuffer(width: 8, height: 8)
        let firstSample = try makeSample(from: first)
        let secondSample = try makeSample(from: second)

        try sink.startStream()
        sink.accept(firstSample, hasMore: false)
        XCTAssertTrue(SharedFrame.shared.latest() === first)

        try sink.stopStream()
        sink.accept(secondSample, hasMore: true)
        XCTAssertTrue(SharedFrame.shared.latest() === first)
    }

    func testSinkStreamConsumesMoreSamplesImmediatelyAndStopsAfterLastItem() throws {
        var consumeCount = 0
        let sink = SinkStreamSource(localizedName: "test") { receive in
            consumeCount += 1
            if consumeCount == 1 { receive(nil, true) }
            else if consumeCount == 2 { receive(nil, false) }
        }

        try sink.startStream()
        XCTAssertEqual(consumeCount, 2, "hasMore should immediately request the next queued sample")
        try sink.stopStream()
        XCTAssertEqual(consumeCount, 2)
    }

    func testDeviceSourceCreatesSourceAndSinkStreams() throws {
        let device = DeviceSource(localizedName: "test")

        XCTAssertEqual(device.streams.count, 2)
        XCTAssertNoThrow(try device.deviceProperties(forProperties: device.availableProperties))
    }

    func testProviderReturnsOnlyRequestedProperties() throws {
        let provider = ProviderSource()
        try provider.setProviderProperties(CMIOExtensionProviderProperties(dictionary: [:]))
        XCTAssertEqual(provider.availableProperties, [.providerManufacturer, .providerName])
        let requested = try provider.providerProperties(forProperties: [.providerName])
        let complete = try provider.providerProperties(forProperties: [.providerName, .providerManufacturer])

        XCTAssertEqual(requested.name, "Android Camera Provider")
        XCTAssertNil(requested.manufacturer)
        XCTAssertEqual(complete.name, "Android Camera Provider")
        XCTAssertEqual(complete.manufacturer, "Android Webcam")
    }

    func testExtensionLoggerInitializesWithoutStartingProviderService() {
        XCTAssertEqual(String(describing: type(of: ExtensionLogger.runtime)), "Logger")
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "CameraExtensionRuntimeTests", code: Int(status))
        }
        return pixelBuffer
    }

    private func makeSample(from pixels: CVPixelBuffer) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else {
            throw NSError(domain: "CameraExtensionRuntimeTests", code: Int(formatStatus))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else {
            throw NSError(domain: "CameraExtensionRuntimeTests", code: Int(sampleStatus))
        }
        return sample
    }
}

private final class FakeCameraFrameProvider: CameraFrameProviding {
    private let sampleValue: CMSampleBuffer
    private let sampleCountLock = NSLock()
    private var sampleCountValue = 0
    var sampleCount: Int {
        sampleCountLock.lock()
        defer { sampleCountLock.unlock() }
        return sampleCountValue
    }

    init(sample: CMSampleBuffer) { sampleValue = sample }

    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer? {
        sampleCountLock.lock()
        sampleCountValue += 1
        sampleCountLock.unlock()
        return sampleValue
    }
}

private final class EmptyCameraFrameProvider: CameraFrameProviding {
    private let sampleCountLock = NSLock()
    private var sampleCountValue = 0
    var sampleCount: Int {
        sampleCountLock.lock()
        defer { sampleCountLock.unlock() }
        return sampleCountValue
    }
    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer? {
        sampleCountLock.lock()
        sampleCountValue += 1
        sampleCountLock.unlock()
        return nil
    }
}

private final class FakeExtensionSamplePublisher: ExtensionSamplePublishing {
    private let onSend: () -> Void
    private let sendCountLock = NSLock()
    private var sendCountValue = 0
    var sendCount: Int {
        sendCountLock.lock()
        defer { sendCountLock.unlock() }
        return sendCountValue
    }

    init(onSend: @escaping () -> Void) { self.onSend = onSend }

    func send(_ sample: CMSampleBuffer, hostTimeNanoseconds: UInt64) {
        sendCountLock.lock()
        sendCountValue += 1
        sendCountLock.unlock()
        onSend()
    }
}

private final class ManualCameraStreamTimer: CameraStreamTiming {
    private var callback: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start(_ tick: @escaping () -> Void) {
        startCount += 1
        callback = tick
    }
    func stop() {
        stopCount += 1
        callback = nil
    }
    func tick() { callback?() }
}

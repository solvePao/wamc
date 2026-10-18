import AppKit
import SwiftUI
import AVFoundation
import CoreVideo
import CoreMediaIO
import XCTest
@testable import AndroidWebcamAppRuntime

final class PreviewBridgeTests: XCTestCase {
    func testUnavailableSinkRetriesDiscoveryAndRecordsSuccessfulEnqueue() throws {
        let sink = FakeExtensionSink()
        var now: TimeInterval = 0
        let bridge = ExtensionBridge(sink: sink, now: { now })
        let sample = try makeSample()

        XCTAssertEqual(sink.discoveryCount, 1)
        bridge.send(sample)
        XCTAssertEqual(sink.discoveryCount, 1)

        now = 3
        sink.becomeAvailableOnDiscovery = true
        bridge.send(sample)
        XCTAssertEqual(sink.discoveryCount, 2)
        XCTAssertEqual(sink.enqueueCount, 1)
        XCTAssertEqual(bridge.lastEnqueuedAt, 3)
        XCTAssertEqual(bridge.connectedStreamName, "Android Camera Sink")
    }

    func testFullQueueTimeoutDisconnectsAndNextSendRediscovers() throws {
        let sink = FakeExtensionSink(available: true)
        var now: TimeInterval = 10
        let bridge = ExtensionBridge(sink: sink, now: { now })
        let sample = try makeSample()
        sink.enqueueResult = .full

        bridge.send(sample)
        XCTAssertEqual(sink.disconnectCount, 0)
        now = 11.1
        bridge.send(sample)
        XCTAssertEqual(sink.disconnectCount, 1)
        XCTAssertNil(bridge.lastEnqueuedAt)

        now = 11.2
        sink.becomeAvailableOnDiscovery = true
        sink.enqueueResult = .accepted
        bridge.send(sample)
        XCTAssertEqual(sink.discoveryCount, 2)
        XCTAssertEqual(bridge.lastEnqueuedAt, now)
    }

    func testFailedEnqueueDoesNotReportFrameAsDeliveredAndBridgeCleansUp() throws {
        let sink = FakeExtensionSink(available: true)
        sink.enqueueResult = .failed
        let sample = try makeSample()

        do {
            let bridge = ExtensionBridge(sink: sink, now: { 5 })
            bridge.send(sample)
            XCTAssertNil(bridge.lastEnqueuedAt)
        }

        XCTAssertEqual(sink.disconnectCount, 1)
    }

    func testBridgeNormalizationPassesThroughFixedFormatAndLetterboxesOtherSizes() throws {
        let fixedFormat = try makePixelBuffer(width: 1920, height: 1080)
        XCTAssertTrue(normalizedBridgePixels(fixedFormat) === fixedFormat)

        let smaller = try makePixelBuffer(width: 640, height: 480)
        let normalized = normalizedBridgePixels(smaller)
        XCTAssertEqual(CVPixelBufferGetWidth(normalized), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(normalized), 1080)
    }

    private func makeSample() throws -> CMSampleBuffer {
        let pixels = try makePixelBuffer(width: 2, height: 2)
        guard let sample = makeImageSampleBuffer(pixels) else {
            throw NSError(domain: "PreviewBridgeTests", code: -1)
        }
        return sample
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                         &pixels)
        guard result == kCVReturnSuccess, let pixels else {
            throw NSError(domain: "PreviewBridgeTests", code: Int(result))
        }
        return pixels
    }
}

private final class FakeExtensionSink: ExtensionFrameSink {
    private(set) var available: Bool
    private(set) var connectedStreamName: String? = "Android Camera Sink"
    private(set) var discoveryCount = 0
    private(set) var enqueueCount = 0
    private(set) var disconnectCount = 0
    var becomeAvailableOnDiscovery = false
    var enqueueResult: ExtensionSinkEnqueueResult = .accepted

    init(available: Bool = false) { self.available = available }

    func discover() {
        discoveryCount += 1
        if becomeAvailableOnDiscovery { available = true }
    }

    func enqueue(_ sample: CMSampleBuffer) -> ExtensionSinkEnqueueResult {
        enqueueCount += 1
        return enqueueResult
    }

    func disconnect() {
        disconnectCount += 1
        available = false
        connectedStreamName = nil
    }
}

extension PreviewBridgeTests {
    func testAcceptedFrameResetsQueueTimeoutAndUnavailableDoesNotClaimDelivery() throws {
        let sink = FakeExtensionSink(available: true)
        var now: TimeInterval = 5
        let bridge = ExtensionBridge(sink: sink, now: { now })
        let sample = try makeSample()
        XCTAssertTrue(bridge.available)
        bridge.discoverSink()
        XCTAssertEqual(sink.discoveryCount, 2)
        sink.enqueueResult = .full
        bridge.send(sample)
        now = 5.5
        sink.enqueueResult = .accepted
        bridge.send(sample)
        XCTAssertEqual(bridge.lastEnqueuedAt, 5.5)
        now = 7
        sink.enqueueResult = .full
        bridge.send(sample)
        XCTAssertEqual(sink.disconnectCount, 0, "Accepted frame resets the full-queue grace period")
        sink.enqueueResult = .unavailable
        bridge.send(sample)
        XCTAssertEqual(bridge.lastEnqueuedAt, 5.5)
    }

    func testPlaceholderHasRequestedSizeAndDarkPixels() throws {
        let buffer = try XCTUnwrap(PlaceholderFrame.make(width: 64, height: 48))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 48)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[0], 24)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
        XCTAssertNil(PlaceholderFrame.make(width: 0, height: 0))
    }

    @MainActor
    func testPreviewRendererMountsAndClearsItsLayer() throws {
        let renderer = PreviewRenderer()
        XCTAssertEqual(renderer.layer.videoGravity, .resizeAspect)
        renderer.enqueue(try makeSample())
        renderer.clear()
        let host = NSHostingView(rootView: PreviewView(renderer: renderer))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        PreviewView.dismantleNSView(host, coordinator: ())
        XCTAssertEqual(host.frame.width, 320)
    }
}

extension PreviewBridgeTests {
    func testNativeSinkDiscoversOnlyWamcAndBalancesQueueSampleOwnership() throws {
        var queue: CMSimpleQueue?
        XCTAssertEqual(CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: 1, queueOut: &queue), noErr)
        let samples = try XCTUnwrap(queue)
        var operations = CoreMediaIOStreamAccess()
        var started: [UInt32] = []
        var stopped: [UInt32] = []
        operations.copyQueue = { stream, callback, _, output in
            XCTAssertEqual(stream, 12)
            output?.pointee = Unmanaged.passRetained(samples)
            callback?(1, nil, nil)
            return noErr
        }
        operations.start = { _, stream in started.append(stream); return noErr }
        operations.stop = { _, stream in stopped.append(stream); return noErr }
        let sink = CoreMediaIOExtensionSink(reader: SinkPropertyReader(), streams: operations)
        let sample = try makeSample()
        if case .unavailable = sink.enqueue(sample) {} else { XCTFail("Disconnected sink must reject frames") }
        sink.discover()
        sink.discover()
        XCTAssertEqual(started, [12], "Discovery must not start an already active stream twice")
        XCTAssertTrue(sink.available)
        XCTAssertEqual(sink.connectedStreamName, "Android Camera Sink")
        if case .accepted = sink.enqueue(sample) {} else { XCTFail("Available queue must accept a frame") }
        if case .full = sink.enqueue(sample) {} else { XCTFail("Queue capacity must be respected") }
        let retained = try XCTUnwrap(CMSimpleQueueDequeue(samples))
        XCTAssertTrue(Unmanaged<CMSampleBuffer>.fromOpaque(retained).takeRetainedValue() === sample)
        sink.disconnect()
        XCTAssertEqual(stopped, [12])
        XCTAssertFalse(sink.available)
        XCTAssertNil(sink.connectedStreamName)
    }

    func testNativeSinkHandlesDiscoveryQueueStartAndEnqueueFailures() throws {
        let sample = try makeSample()
        let missing = CoreMediaIOExtensionSink(reader: SinkPropertyReader(failSystem: true))
        missing.discover()
        XCTAssertFalse(missing.available)
        var operations = CoreMediaIOStreamAccess()
        operations.copyQueue = { _, _, _, _ in -1 }
        let noQueue = CoreMediaIOExtensionSink(reader: SinkPropertyReader(), streams: operations)
        noQueue.discover()
        XCTAssertFalse(noQueue.available)
        operations.copyQueue = { _, _, _, _ in noErr }
        let emptyQueue = CoreMediaIOExtensionSink(reader: SinkPropertyReader(), streams: operations)
        emptyQueue.discover()
        XCTAssertFalse(emptyQueue.available)
        var queue: CMSimpleQueue?
        XCTAssertEqual(CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: 1, queueOut: &queue), noErr)
        let samples = try XCTUnwrap(queue)
        operations.copyQueue = { _, _, _, output in output?.pointee = Unmanaged.passRetained(samples); return noErr }
        operations.start = { _, _ in -1 }
        let failedStart = CoreMediaIOExtensionSink(reader: SinkPropertyReader(), streams: operations)
        failedStart.discover()
        XCTAssertFalse(failedStart.available)
        operations.start = { _, _ in noErr }
        operations.stop = { _, _ in noErr }
        operations.enqueue = { _, _ in -1 }
        let failedEnqueue = CoreMediaIOExtensionSink(reader: SinkPropertyReader(), streams: operations)
        failedEnqueue.discover()
        if case .failed = failedEnqueue.enqueue(sample) {} else { XCTFail("Native enqueue error must be reported") }
        XCTAssertEqual(CMSimpleQueueGetCount(samples), 0)
        failedEnqueue.disconnect()
    }
}

private struct SinkPropertyReader: CoreMediaIOPropertyReading {
    var failSystem = false
    func objects(for object: UInt32, selector: UInt32) throws -> [UInt32] {
        if object == UInt32(kCMIOObjectSystemObject) {
            if failSystem { throw NSError(domain: "CMIO.Test", code: -1) }
            return [10, 20]
        }
        if object == 20 { throw NSError(domain: "CMIO.Test", code: -2) }
        return [11, 12, 13]
    }
    func string(for object: UInt32, selector: UInt32) throws -> String? {
        switch object {
        case 11: return "OBS Virtual Camera Sink"
        case 12: return "Android Camera Sink"
        default: return nil
        }
    }
}

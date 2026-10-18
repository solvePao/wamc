import AppKit
import SwiftUI
import AVFoundation
import CoreVideo
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

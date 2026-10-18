import XCTest
import CoreVideo
@testable import AndroidWebcamCore

final class FrameOrientationTests: XCTestCase {
    func testClockwiseRotationPreservesPixelPositions() throws {
        let source = try makeImage()
        let expected: [[UInt32]] = [
            [1, 2, 3, 4, 5, 6, 7, 8],
            [5, 1, 6, 2, 7, 3, 8, 4],
            [8, 7, 6, 5, 4, 3, 2, 1],
            [4, 8, 3, 7, 2, 6, 1, 5],
        ]
        for turns in 0..<4 {
            let result = FrameRotation.rotate(source, quarterTurns: turns)
            XCTAssertEqual(CVPixelBufferGetWidth(result), turns % 2 == 0 ? 4 : 2)
            XCTAssertEqual(CVPixelBufferGetHeight(result), turns % 2 == 0 ? 2 : 4)
            XCTAssertEqual(pixels(result), expected[turns].map(color), "rotation \(turns)")
        }
    }

    func testDelayedFramesAndConfigUpdatesAreRejected() throws {
        let tracker = StreamFrameContextTracker()
        tracker.advanceConnection()
        let first = try XCTUnwrap(tracker.configure(key: "front:portrait", rotation: 3))
        XCTAssertNil(tracker.configure(key: "front:portrait", rotation: 3))
        let rotated = try XCTUnwrap(tracker.configure(key: "front:landscape", rotation: 0))
        XCTAssertFalse(tracker.accepts(first)) // delayed decode or queued status update
        XCTAssertTrue(tracker.accepts(rotated))
        tracker.resetConfiguration()
        XCTAssertFalse(tracker.accepts(rotated))
        let restarted = try XCTUnwrap(tracker.configure(key: "front:landscape", rotation: 0))
        XCTAssertNotEqual(rotated.configurationRevision, restarted.configurationRevision)
        tracker.advanceConnection()
        let reconnected = try XCTUnwrap(tracker.configure(key: "front:landscape", rotation: 0))
        XCTAssertFalse(tracker.accepts(restarted))
        XCTAssertNotEqual(restarted.connectionEpoch, reconnected.connectionEpoch)
        XCTAssertTrue(tracker.accepts(reconnected))
    }

    func testQueuedFrameRetainsItsOwnOrientation() throws {
        let tracker = StreamFrameContextTracker()
        let first = try XCTUnwrap(tracker.configure(key: "portrait", rotation: 3))
        let queue = LatestFrameQueue()
        queue.enqueue(try makeImage(), context: first)
        _ = tracker.configure(key: "landscape", rotation: 0)
        let delayed = try XCTUnwrap(queue.dequeueLatestFrame())
        XCTAssertEqual(delayed.context?.rotation, 3)
        XCTAssertFalse(tracker.accepts(try XCTUnwrap(delayed.context)))
    }

    func testDeferredStartKeepsExistingFramesUntilConfigArrives() throws {
        let tracker = StreamFrameContextTracker()
        let active = try XCTUnwrap(tracker.configure(key: "front", rotation: 3))
        tracker.allowRepeatedConfiguration()
        XCTAssertTrue(tracker.accepts(active))
        let replacement = try XCTUnwrap(tracker.configure(key: "front", rotation: 3))
        XCTAssertFalse(tracker.accepts(active))
        XCTAssertTrue(tracker.accepts(replacement))
    }

    private func color(_ index: UInt32) -> UInt32 {
        // Eight distinct opaque colors avoid alpha/color-space rounding.
        0xff000000 | ((index & 1) != 0 ? 0xff : 0) |
            ((index & 2) != 0 ? 0xff00 : 0) | ((index & 4) != 0 ? 0xff0000 : 0)
    }

    private func makeImage() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &result), kCVReturnSuccess)
        let image = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<2 {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<4 { row[x] = color(UInt32(y * 4 + x + 1)) }
        }
        return image
    }

    private func pixels(_ image: CVPixelBuffer) -> [UInt32] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(image)!
        let stride = CVPixelBufferGetBytesPerRow(image)
        return (0..<CVPixelBufferGetHeight(image)).flatMap { y in
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            return (0..<CVPixelBufferGetWidth(image)).map { row[$0] }
        }
    }
}

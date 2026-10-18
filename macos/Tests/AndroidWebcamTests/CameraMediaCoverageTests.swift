import CoreMedia
import CoreVideo
import XCTest
@testable import CameraExtensionRuntime

final class CameraMediaCoverageTests: XCTestCase {
    func testStreamFormatRejectsOSFailureAndMissingDescription() {
        XCTAssertNil(makeFormat(factory: FailingCameraMediaFactory(.streamFormat)))
        XCTAssertNil(makeFormat(factory: FailingCameraMediaFactory(.missingStreamFormat)))
        XCTAssertNotNil(makeFormat())
    }

    func testSampleCreationRejectsFormatAndSampleAllocationFailures() throws {
        let pixels = try XCTUnwrap(CameraMediaFactory().placeholderBuffer().1)
        for failure in [MediaFailure.imageFormat, .missingImageFormat, .sample] {
            XCTAssertNil(makeSample(from: pixels, format: nil, hostTime: .zero,
                                    factory: FailingCameraMediaFactory(failure)))
        }
        let format = try XCTUnwrap(CameraMediaFactory().imageFormat(pixels).1)
        let time = CMTime(value: 123, timescale: 30)
        let sample = try XCTUnwrap(makeSample(from: pixels, format: format, hostTime: time))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), time)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === pixels)
    }

    func testPlaceholderRejectsAllocationFailureAndFillsValidPixels() throws {
        XCTAssertNil(makePlaceholder(factory: FailingCameraMediaFactory(.placeholder)))
        XCTAssertNil(makePlaceholder(factory: FailingCameraMediaFactory(.missingPlaceholder)))
        let pixels = try XCTUnwrap(makePlaceholder())
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 1080)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        XCTAssertEqual(base.load(as: UInt8.self), 24)
    }

    func testProviderReturnsNoSampleWhenBothLiveFrameAndPlaceholderAreAbsent() {
        let provider = SharedCameraFrameProvider(sharedFrame: SharedFrame(), placeholder: nil)
        XCTAssertNil(provider.sample(format: nil, hostTime: .zero))
    }
}

private enum MediaFailure {
    case streamFormat, missingStreamFormat, imageFormat, missingImageFormat
    case sample, placeholder, missingPlaceholder
}

private struct FailingCameraMediaFactory: CameraMediaCreating {
    let failure: MediaFailure
    init(_ failure: MediaFailure) { self.failure = failure }
    func streamFormat() -> (OSStatus, CMVideoFormatDescription?) {
        if failure == .streamFormat { return (-1, nil) }
        if failure == .missingStreamFormat { return (noErr, nil) }
        return CameraMediaFactory().streamFormat()
    }
    func imageFormat(_ pixels: CVPixelBuffer) -> (OSStatus, CMVideoFormatDescription?) {
        if failure == .imageFormat { return (-1, nil) }
        if failure == .missingImageFormat { return (noErr, nil) }
        return CameraMediaFactory().imageFormat(pixels)
    }
    func sampleBuffer(_ pixels: CVPixelBuffer, format: CMFormatDescription,
                      hostTime: CMTime) -> (OSStatus, CMSampleBuffer?) {
        if failure == .sample { return (-1, nil) }
        return CameraMediaFactory().sampleBuffer(pixels, format: format, hostTime: hostTime)
    }
    func placeholderBuffer() -> (CVReturn, CVPixelBuffer?) {
        if failure == .placeholder { return (-1, nil) }
        if failure == .missingPlaceholder { return (kCVReturnSuccess, nil) }
        return CameraMediaFactory().placeholderBuffer()
    }
}

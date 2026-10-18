import XCTest
import VideoToolbox
import CoreMedia
@testable import AndroidWebcamCore
@testable import AndroidWebcamProtocol
@testable import AndroidWebcamAppRuntime

final class AdditionalDecoderCoverageTests: XCTestCase {
    func testAllocationFailuresRequestKeyframeRecoveryWithoutSubmittingSample() throws {
        for failBlock in [true, false] {
            let buffers = FailingDecoderBuffers(failBlock: failBlock)
            let session = CountingDecoderSession()
            let decoder = H264Decoder(sessionFactory: { _, _, _ in (noErr, session) },
                formatFactory: { _, _, width, height in
                    var format: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                        width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &format)
                    return (status, format)
                }, bufferFactory: buffers)
            let context = try XCTUnwrap(StreamFrameContextTracker().configure(key: "allocation", rotation: 0))
            var errors: [StreamFrameContext] = []
            decoder.onError = { errors.append($0) }
            decoder.configure(withV2: .init(codec: 0, paramSets: [Data([0x67]), Data([0x68])],
                                            width: 16, height: 16, fps: 30), context: context)
            decoder.decode(annexB: Data([0, 0, 1, 0x65]), ptsUs: 0, isKeyframe: true)
            XCTAssertEqual(errors, [context])
            XCTAssertEqual(session.decodeCount, 0)
            decoder.decode(annexB: Data([0, 0, 1, 0x41]), ptsUs: 1, isKeyframe: false)
            XCTAssertEqual(errors, [context], "Inter frames are dropped until a new keyframe after allocation failure")
            XCTAssertEqual(buffers.blockCalls, 1)
            decoder.invalidate()
            XCTAssertEqual(session.invalidations, 1)
        }
    }

    func testEmptyParameterBufferProducesFormatError() {
        let result = H264Decoder.makeFormatDescription(WireProtocol.codecAVC, [Data()], 16, 16)
        XCTAssertNotEqual(result.status, noErr)
        XCTAssertNil(result.format)
    }

    func testSystemDecoderProcessesLocallyEncodedFrame() async throws {
        let fixture = try encodeFrame()
        let decoder = H264Decoder()
        let context = try XCTUnwrap(StreamFrameContextTracker().configure(key: "system", rotation: 0))
        let decoded = expectation(description: "system VideoToolbox decoder delivers frame")
        decoder.onError = { _ in XCTFail("The locally encoded frame must decode") }
        decoder.onPixelBuffer = { pixels, pts, deliveredContext in
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), 16)
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), 16)
            XCTAssertEqual(pts, 42_000)
            XCTAssertEqual(deliveredContext, context)
            decoded.fulfill()
        }
        decoder.configure(with: fixture.config, context: context)
        // Reconfiguration must drain and invalidate the former system session.
        decoder.configure(with: fixture.config, context: context)
        decoder.decode(annexB: fixture.frame, ptsUs: 42_000, isKeyframe: true)
        await fulfillment(of: [decoded], timeout: 5)
        decoder.invalidate()
    }

    private func encodeFrame() throws -> (config: WireProtocol.Config, frame: Data) {
        let encoded = EncodedSample()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 16, height: 16,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { refCon, _, status, _, sample in
                let target = Unmanaged<EncodedSample>.fromOpaque(refCon!).takeUnretainedValue()
                target.status = status
                target.sample = sample
            }, refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &session)
        XCTAssertEqual(status, noErr)
        let encoder = try XCTUnwrap(session)
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 30),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertEqual(encoded.status, noErr)
        let sample = try XCTUnwrap(encoded.sample)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        var sets: [Data] = []
        for index in 0..<2 {
            var bytes: UnsafePointer<UInt8>?
            var count = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &bytes,
                parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), noErr)
            sets.append(Data(bytes: try XCTUnwrap(bytes), count: count))
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copyStatus = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        XCTAssertEqual(copyStatus, noErr)
        var annexB = Data()
        var offset = 0
        while offset + 4 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            XCTAssertLessThanOrEqual(offset + length, data.count)
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(data[offset..<offset + length])
            offset += length
        }
        return (.init(sps: sets[0], pps: sets[1], width: 16, height: 16, fps: 30), annexB)
    }
}

private final class EncodedSample {
    var status: OSStatus = -1
    var sample: CMSampleBuffer?
}

private final class CountingDecoderSession: VideoToolboxDecodingSession {
    var decodeCount = 0
    var invalidations = 0
    func configureRealtime() {}
    func decode(_ sampleBuffer: CMSampleBuffer) -> OSStatus { decodeCount += 1; return noErr }
    func invalidate() { invalidations += 1 }
}

private final class FailingDecoderBuffers: DecoderBufferCreating {
    let failBlock: Bool
    var blockCalls = 0
    init(failBlock: Bool) { self.failBlock = failBlock }
    func makeBlockBuffer(length: Int) -> CMBlockBuffer? {
        blockCalls += 1
        guard !failBlock else { return nil }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &block)
        return block
    }
    func makeSampleBuffer(block: CMBlockBuffer, format: CMVideoFormatDescription,
                          timing: inout CMSampleTimingInfo, size: Int) -> CMSampleBuffer? { nil }
}

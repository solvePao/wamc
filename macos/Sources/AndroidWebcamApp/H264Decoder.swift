import Foundation
import VideoToolbox
import CoreMedia
import AndroidWebcamCore
import AndroidWebcamProtocol
import OSLog

/// Hardware decoding (AVC + HEVC) via VTDecompressionSession (VideoToolbox).
/// Output carries the orientation and identity of the session that decoded it.
protocol H264Decoding: AnyObject {
    var onPixelBuffer: ((CVPixelBuffer, Int64, StreamFrameContext) -> Void)? { get set }
    var onError: ((StreamFrameContext) -> Void)? { get set }
    func configure(with config: WireProtocol.Config, context: StreamFrameContext)
    func configure(withV2 config: WireProtocol.ConfigV2, context: StreamFrameContext)
    func decode(annexB: Data, ptsUs: Int64, isKeyframe: Bool)
    func invalidate()
}

typealias VideoToolboxSessionFactory = (
    CMVideoFormatDescription,
    inout VTDecompressionOutputCallbackRecord,
    CFDictionary
) -> (status: OSStatus, session: VideoToolboxDecodingSession?)
typealias DecoderFormatFactory = (
    Int, [Data], Int, Int
) -> (status: OSStatus, format: CMVideoFormatDescription?)

protocol VideoToolboxDecodingSession: AnyObject {
    func configureRealtime()
    func decode(_ sampleBuffer: CMSampleBuffer) -> OSStatus
    func invalidate()
}

private final class SystemVideoToolboxDecodingSession: VideoToolboxDecodingSession {
    private let session: VTDecompressionSession

    init(_ session: VTDecompressionSession) { self.session = session }

    func configureRealtime() {
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
    }

    func decode(_ sampleBuffer: CMSampleBuffer) -> OSStatus {
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
                                          flags: VTDecodeFrameFlags(rawValue: 1 << 0),
                                          frameRefcon: nil, infoFlagsOut: nil)
    }

    func invalidate() {
        _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }
}

final class H264Decoder: H264Decoding {
    private let sessionFactory: VideoToolboxSessionFactory
    private let formatFactory: DecoderFormatFactory
    private let lock = NSLock()
    private var session: VideoToolboxDecodingSession?
    private var formatDescription: CMVideoFormatDescription?
    private var needsKeyframe = true
    private var outputContext: DecoderOutputContext?
    var onPixelBuffer: ((CVPixelBuffer, Int64, StreamFrameContext) -> Void)?
    var onError: ((StreamFrameContext) -> Void)?

    init(sessionFactory: @escaping VideoToolboxSessionFactory = H264Decoder.createSession,
         formatFactory: @escaping DecoderFormatFactory = H264Decoder.makeFormatDescription) {
        self.sessionFactory = sessionFactory
        self.formatFactory = formatFactory
    }

    func configure(with config: WireProtocol.Config, context: StreamFrameContext) {
        let sps = stripStartCode(config.sps)
        let pps = stripStartCode(config.pps)
        guard !sps.isEmpty, !pps.isEmpty else {
            AppLogger.stream.error("Rejected AVC decoder configuration with empty parameter sets")
            invalidate()
            onError?(context)
            return
        }
        let result = formatFactory(WireProtocol.codecAVC, [sps, pps], config.width, config.height)
        guard result.status == noErr, let format = result.format else {
            AppLogger.stream.error("Creating AVC format description failed with OSStatus \(result.status, privacy: .public)")
            invalidate()
            onError?(context)
            return
        }
        applyNewSession(format: format, context: context)
    }

    /// Codec-negotiated path: HEVC carries vps/sps/pps, AVC sps/pps.
    func configure(withV2 config: WireProtocol.ConfigV2, context: StreamFrameContext) {
        let sets = config.paramSets.map { stripStartCode($0) }
        guard sets.count >= 2, sets.allSatisfy({ !$0.isEmpty }) else {
            AppLogger.stream.error("Rejected negotiated decoder configuration with invalid parameter sets")
            invalidate()
            onError?(context)
            return
        }
        let result = formatFactory(config.codec, sets, config.width, config.height)
        guard result.status == noErr, let format = result.format else {
            AppLogger.stream.error("Creating negotiated format description failed with OSStatus \(result.status, privacy: .public)")
            invalidate()
            onError?(context)
            return
        }
        applyNewSession(format: format, context: context)
    }

    private final class DecoderOutputContext {
        weak var decoder: H264Decoder?
        let frameContext: StreamFrameContext

        init(decoder: H264Decoder, frameContext: StreamFrameContext) {
            self.decoder = decoder
            self.frameContext = frameContext
        }
    }

    private func applyNewSession(format: CMVideoFormatDescription, context: StreamFrameContext) {
        let output = DecoderOutputContext(decoder: self, frameContext: context)
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
                guard let refCon else { return }
                let output = Unmanaged<DecoderOutputContext>.fromOpaque(refCon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    output.decoder?.onError?(output.frameContext)
                    return
                }
                output.decoder?.onPixelBuffer?(imageBuffer, Int64(pts.seconds * 1_000_000), output.frameContext)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let creation = sessionFactory(format, &callback, attrs as CFDictionary)
        let createStatus = creation.status
        guard createStatus == noErr, let newSession = creation.session else {
            AppLogger.stream.error("Creating VideoToolbox decoder session failed with OSStatus \(createStatus, privacy: .public)")
            invalidate()
            onError?(context)
            return
        }
        newSession.configureRealtime()

        let oldSession: VideoToolboxDecodingSession?
        let oldOutput: DecoderOutputContext?
        lock.lock()
        oldSession = session
        oldOutput = outputContext
        session = newSession
        outputContext = output
        formatDescription = format
        needsKeyframe = true
        lock.unlock()

        oldSession?.invalidate()
        withExtendedLifetime(oldOutput) {}
    }

    func decode(annexB: Data, ptsUs: Int64, isKeyframe: Bool = false) {
        var notifyError = false
        lock.lock()
        guard let session, let formatDescription, let context = outputContext?.frameContext else {
            lock.unlock()
            return
        }
        if isKeyframe {
            needsKeyframe = false
        } else if needsKeyframe {
            lock.unlock()
            return
        }

        let avcc = H264.annexBToAVCC(annexB)
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else {
            needsKeyframe = true
            lock.unlock()
            AppLogger.stream.error("Creating decoder block buffer failed")
            onError?(context)
            return
        }
        avcc.withUnsafeBytes { src in
            if let base = src.baseAddress {
                _ = CMBlockBufferReplaceDataBytes(with: base,
                                                  blockBuffer: blockBuffer,
                                                  offsetIntoDestination: 0,
                                                  dataLength: avcc.count)
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        var sizes = [avcc.count]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else {
            needsKeyframe = true
            lock.unlock()
            AppLogger.stream.error("Creating decoder sample buffer failed")
            onError?(context)
            return
        }
        let status = session.decode(sampleBuffer)
        if status != noErr {
            AppLogger.stream.error("Submitting frame to VideoToolbox failed with OSStatus \(status, privacy: .public)")
            needsKeyframe = true
            notifyError = true
        }
        lock.unlock()

        if notifyError {
            onError?(context)
        }
    }

    func invalidate() {
        let oldSession: VideoToolboxDecodingSession?
        let oldOutput: DecoderOutputContext?
        lock.lock()
        oldSession = session
        oldOutput = outputContext
        session = nil
        outputContext = nil
        formatDescription = nil
        needsKeyframe = true
        lock.unlock()

        if let oldSession {
            oldSession.invalidate()
        }
        withExtendedLifetime(oldOutput) {}
    }

    deinit { invalidate() }

    private func stripStartCode(_ data: Data) -> Data {
        if data.starts(with: [0, 0, 0, 1]) { return data.dropFirst(4) }
        if data.starts(with: [0, 0, 1]) { return data.dropFirst(3) }
        return data
    }

    private static func createSession(
        format: CMVideoFormatDescription,
        callback: inout VTDecompressionOutputCallbackRecord,
        attributes: CFDictionary
    ) -> (status: OSStatus, session: VideoToolboxDecodingSession?) {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes,
            outputCallback: &callback, decompressionSessionOut: &session)
        guard status == noErr, let session else { return (status, nil) }
        return (status, SystemVideoToolboxDecodingSession(session))
    }

    /// Holds every parameter-set byte buffer alive until CoreMedia has consumed its pointers.
    private static func makeFormatDescription(
        _ codec: Int, _ sets: [Data], _ width: Int, _ height: Int
    ) -> (status: OSStatus, format: CMVideoFormatDescription?) {
        var format: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func build(_ index: Int) -> OSStatus {
            guard index < sets.count else {
                if codec == WireProtocol.codecHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &format)
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
            return sets[index].withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_ValueNotAvailable)
                }
                pointers.append(base.assumingMemoryBound(to: UInt8.self))
                sizes.append(sets[index].count)
                defer { pointers.removeLast(); sizes.removeLast() }
                return build(index + 1)
            }
        }
        return (build(0), format)
    }
}

import Foundation
import VideoToolbox
import CoreMedia
import AndroidWebcamCore
import AndroidWebcamProtocol

/// Hardware decoding (AVC + HEVC) via VTDecompressionSession (VideoToolbox).
/// The Mac never filters pixels: it decodes and forwards; rotation and
/// enhancement already happened on the phone.
final class H264Decoder {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var needsKeyframe = true
    var onPixelBuffer: ((CVPixelBuffer, Int64) -> Void)?
    var onError: (() -> Void)?

    func configure(with config: WireProtocol.Config) {
        let sps = stripStartCode(config.sps)
        let pps = stripStartCode(config.pps)
        guard !sps.isEmpty, !pps.isEmpty else {
            invalidate()
            onError?()
            return
        }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_ValueNotAvailable)
                }
                let pointers = [spsBase.assumingMemoryBound(to: UInt8.self),
                                ppsBase.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            invalidate()
            onError?()
            return
        }
        applyNewSession(format: format)
    }

    /// Codec-negotiated path: HEVC carries vps/sps/pps, AVC sps/pps.
    /// Pointer lifetimes nest via recursion: each set is pinned by its own
    /// withUnsafeBytes frame while deeper frames run.
    func configure(withV2 config: WireProtocol.ConfigV2) {
        let sets = config.paramSets.map { stripStartCode($0) }
        guard sets.count >= 2, sets.allSatisfy({ !$0.isEmpty }) else {
            invalidate()
            onError?()
            return
        }
        var format: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func build(_ index: Int) -> OSStatus {
            if index == sets.count {
                if config.codec == WireProtocol.codecHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
            return sets[index].withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_ValueNotAvailable)
                }
                pointers.append(base.assumingMemoryBound(to: UInt8.self))
                sizes.append(sets[index].count)
                defer { pointers.removeLast(); sizes.removeLast() }
                return build(index + 1)
            }
        }
        let status = build(0)
        guard status == noErr, let format else {
            invalidate()
            onError?()
            return
        }
        applyNewSession(format: format)
    }

    private func applyNewSession(format: CMVideoFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
                guard status == noErr, let imageBuffer, let refCon else { return }
                Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
                    .onPixelBuffer?(imageBuffer, Int64(pts.seconds * 1_000_000))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &newSession)
        guard createStatus == noErr, let newSession else {
            invalidate()
            onError?()
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)

        let oldSession: VTDecompressionSession?
        lock.lock()
        oldSession = session
        session = newSession
        formatDescription = format
        needsKeyframe = true
        lock.unlock()

        if let oldSession {
            VTDecompressionSessionInvalidate(oldSession)
        }
    }

    func decode(annexB: Data, ptsUs: Int64, isKeyframe: Bool = false) {
        var notifyError = false
        lock.lock()
        guard let session, let formatDescription else {
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
            onError?()
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
            onError?()
            return
        }
        let flags = VTDecodeFrameFlags(rawValue: 1 << 0) // enable asynchronous
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
                                                       flags: flags, frameRefcon: nil,
                                                       infoFlagsOut: nil)
        if status != noErr {
            needsKeyframe = true
            notifyError = true
        }
        lock.unlock()

        if notifyError {
            onError?()
        }
    }

    func invalidate() {
        let oldSession: VTDecompressionSession?
        lock.lock()
        oldSession = session
        session = nil
        formatDescription = nil
        needsKeyframe = true
        lock.unlock()

        if let oldSession {
            VTDecompressionSessionInvalidate(oldSession)
        }
    }

    deinit { invalidate() }

    private func stripStartCode(_ data: Data) -> Data {
        if data.starts(with: [0, 0, 0, 1]) { return data.dropFirst(4) }
        if data.starts(with: [0, 0, 1]) { return data.dropFirst(3) }
        return data
    }
}

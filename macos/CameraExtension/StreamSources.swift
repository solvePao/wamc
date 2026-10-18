import Foundation
import CoreMediaIO
import CoreVideo

private func makeFormat() -> CMIOExtensionStreamFormat? {
    var description: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: CMVideoCodecType(0x4247_5241), // 'BGRA'
        width: 1920, height: 1080, extensions: nil,
        formatDescriptionOut: &description)
    guard let description else { return nil }
    return CMIOExtensionStreamFormat(
        formatDescription: description,
        maxFrameDuration: CMTime(value: 1, timescale: 30),
        minFrameDuration: CMTime(value: 1, timescale: 30),
        validFrameDurations: nil)
}

private func makeSample(from pixelBuffer: CVPixelBuffer,
                        format: CMFormatDescription?,
                        sequence: UInt64) -> CMSampleBuffer? {
    var resolved = format
    if resolved == nil {
        var created: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &created)
        resolved = created
    }
    guard let resolved else { return nil }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30),
        decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: resolved,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

private let cachedPlaceholder: CVPixelBuffer? = {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 24, CVPixelBufferGetDataSize(buffer)) // "waiting for phone" slate
    }
    return buffer
}()

/// Publishes the latest sink frame (or placeholder) at 30 FPS to meeting apps.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    weak var stream: CMIOExtensionStream?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt64 = 0
    private let queue = DispatchQueue(label: "awc.source")
    private let format = makeFormat()

    init(localizedName: String) { super.init() }

    var formats: [CMIOExtensionStreamFormat] {
        format.map { [$0] } ?? []
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamMaxFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        CMIOExtensionStreamProperties(dictionary: [
            .streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: 0 as NSNumber),
            .streamFrameDuration: CMIOExtensionPropertyState<AnyObject>(
                value: CMTime(value: 1, timescale: 30) as AnyObject),
            .streamMaxFrameDuration: CMIOExtensionPropertyState<AnyObject>(
                value: CMTime(value: 1, timescale: 30) as AnyObject),
        ])
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, let stream = self.stream else { return }
            self.sequence += 1
            let pixels = SharedFrame.shared.latest() ?? cachedPlaceholder
            guard let pixels,
                  let sample = makeSample(from: pixels,
                                          format: self.format?.formatDescription,
                                          sequence: self.sequence) else { return }
            stream.send(sample, discontinuity: [],
                        hostTimeInNanoseconds: UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
        }
        timer.resume()
        self.timer = timer
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }
}

/// Accepts frames from the Mac app (ExtensionBridge) into SharedFrame.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    weak var stream: CMIOExtensionStream?
    private var client: CMIOExtensionClient?
    private var isStreaming = false
    private let format = makeFormat()

    init(localizedName: String) { super.init() }

    var formats: [CMIOExtensionStreamFormat] {
        format.map { [$0] } ?? []
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        CMIOExtensionStreamProperties(dictionary: [
            .streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: 0 as NSNumber),
            .streamFrameDuration: CMIOExtensionPropertyState<AnyObject>(
                value: CMTime(value: 1, timescale: 30) as AnyObject),
            .streamSinkBufferQueueSize: CMIOExtensionPropertyState<AnyObject>(value: 30 as NSNumber),
            .streamSinkBuffersRequiredForStartup: CMIOExtensionPropertyState<AnyObject>(value: 1 as NSNumber),
        ])
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        isStreaming = true
        consumeLoop()
    }

    func stopStream() throws {
        isStreaming = false
        client = nil
    }

    private func consumeLoop() {
        guard isStreaming, let stream, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sample, _, _, hasMore, _ in
            guard let self, self.isStreaming else { return }
            if let sample, let pixels = CMSampleBufferGetImageBuffer(sample) {
                SharedFrame.shared.store(pixels)
            }
            if hasMore {
                self.consumeLoop()
            } else {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                    self?.consumeLoop()
                }
            }
        }
    }
}

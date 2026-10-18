#if WAMC_COVERAGE_TESTING
import AndroidWebcamCore
#endif
import Foundation
import CoreMediaIO
import CoreVideo
import OSLog

func makeFormat(factory: CameraMediaCreating = CameraMediaFactory()) -> CMIOExtensionStreamFormat? {
    let (status, description) = factory.streamFormat()
    guard status == noErr, let description else {
        ExtensionLogger.runtime.error("Creating camera stream format failed with OSStatus \(status, privacy: .public)")
        return nil
    }
    return CMIOExtensionStreamFormat(
        formatDescription: description,
        maxFrameDuration: CMTime(value: 1, timescale: 30),
        minFrameDuration: CMTime(value: 1, timescale: 30),
        validFrameDurations: nil)
}

func makeSample(from pixelBuffer: CVPixelBuffer,
                format: CMFormatDescription?, hostTime: CMTime,
                factory: CameraMediaCreating = CameraMediaFactory()) -> CMSampleBuffer? {
    var resolved = format
    // Color and layout attachments can differ between decoded and placeholder
    // buffers, even when both use the advertised BGRA dimensions.
    if resolved.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) != true {
        let (status, created) = factory.imageFormat(pixelBuffer)
        guard status == noErr else {
            ExtensionLogger.runtime.error("Creating camera image format failed with OSStatus \(status, privacy: .public)")
            return nil
        }
        resolved = created
    }
    guard let resolved else { return nil }
    let (status, sample) = factory.sampleBuffer(pixelBuffer, format: resolved, hostTime: hostTime)
    guard status == noErr else {
        ExtensionLogger.runtime.error("Creating camera sample buffer failed with OSStatus \(status, privacy: .public)")
        return nil
    }
    return sample
}

func makePlaceholder(factory: CameraMediaCreating = CameraMediaFactory()) -> CVPixelBuffer? {
    let (status, buffer) = factory.placeholderBuffer()
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 24, CVPixelBufferGetDataSize(buffer)) // "waiting for phone" slate
    }
    return buffer
}

private let cachedPlaceholder = makePlaceholder()

protocol CameraFrameProviding {
    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer?
}

protocol ExtensionSamplePublishing: AnyObject {
    func send(_ sample: CMSampleBuffer, hostTimeNanoseconds: UInt64)
}

struct SharedCameraFrameProvider: CameraFrameProviding {
    private let sharedFrame: SharedFrame
    private let placeholder: CVPixelBuffer?

    init(sharedFrame: SharedFrame = .shared, placeholder: CVPixelBuffer? = cachedPlaceholder) {
        self.sharedFrame = sharedFrame
        self.placeholder = placeholder
    }

    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer? {
        let frame = sharedFrame.freshFrame(within: 1.0)
        guard let pixels = frame?.pixels ?? placeholder,
              let sample = makeSample(from: pixels, format: format, hostTime: hostTime) else { return nil }
        if let frame {
            CMSetAttachment(sample, key: CameraHealthSnapshot.liveSequenceAttachment as CFString,
                            value: NSNumber(value: frame.sequence), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }
        return sample
    }
}

private final class CMIOExtensionSamplePublisher: ExtensionSamplePublishing {
    weak var stream: CMIOExtensionStream?
    init(stream: CMIOExtensionStream) { self.stream = stream }

    func send(_ sample: CMSampleBuffer, hostTimeNanoseconds: UInt64) {
        guard let stream else { return }
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTimeNanoseconds)
        if let sequence = CMGetAttachment(sample,
            key: CameraHealthSnapshot.liveSequenceAttachment as CFString,
            attachmentModeOut: nil) as? NSNumber {
            SharedFrame.shared.notePublished(sequence: sequence.uint64Value)
        }
    }
}

/// Publishes the latest sink frame (or placeholder) at 30 FPS to meeting apps.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    var stream: CMIOExtensionStream? {
        didSet { publisher = stream.map(CMIOExtensionSamplePublisher.init(stream:)) }
    }
    private let timer: CameraStreamTiming
    private var streamingClients = 0
    private let format = makeFormat()
    private let frameProvider: CameraFrameProviding
    private var publisher: ExtensionSamplePublishing?

    init(localizedName: String, frameProvider: CameraFrameProviding = SharedCameraFrameProvider(),
         publisher: ExtensionSamplePublishing? = nil, timer: CameraStreamTiming = CameraStreamTimer()) {
        self.frameProvider = frameProvider
        self.publisher = publisher
        self.timer = timer
        super.init()
    }

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
                value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 30), allocator: nil)!),
            .streamMaxFrameDuration: CMIOExtensionPropertyState<AnyObject>(
                value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 30), allocator: nil)!),
        ])
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        streamingClients += 1
        guard streamingClients == 1 else { return }
        timer.start { [weak self] in
            guard let self, let publisher = self.publisher else { return }
            // Both timestamps must use the .hostTime clock advertised by the
            // stream. Unix wall time and a zero-based frame counter do not.
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            // Stale frames read as a freeze in meeting apps: fall back to the
            // waiting slate until the Mac app delivers again.
            guard let sample = self.frameProvider.sample(
                format: self.format?.formatDescription, hostTime: hostTime) else { return }
            publisher.send(sample, hostTimeNanoseconds: UInt64(CMTimeConvertScale(
                hostTime, timescale: 1_000_000_000, method: .default).value))
        }
    }

    func stopStream() throws {
        guard streamingClients > 0 else { return }
        streamingClients -= 1
        guard streamingClients == 0 else { return }
        timer.stop()
    }
}

/// Accepts frames from the Mac app (ExtensionBridge) into SharedFrame.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    weak var stream: CMIOExtensionStream?
    private var client: CMIOExtensionClient?
    private var isStreaming = false
    private let format = makeFormat()
    private let injectedConsumer: ((@escaping (CMSampleBuffer?, Bool) -> Void) -> Void)?

    init(localizedName: String) {
        injectedConsumer = nil
        super.init()
    }

    init(localizedName: String,
         consumeSamples: @escaping (@escaping (CMSampleBuffer?, Bool) -> Void) -> Void) {
        injectedConsumer = consumeSamples
        super.init()
    }

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
                value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 30), allocator: nil)!),
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
        guard isStreaming else { return }
        if let injectedConsumer {
            injectedConsumer { [weak self] sample, hasMore in
                self?.accept(sample, hasMore: hasMore)
            }
            return
        }
        guard let stream, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sample, _, _, hasMore, _ in
            self?.accept(sample, hasMore: hasMore)
        }
    }

    func accept(_ sample: CMSampleBuffer?, hasMore: Bool) {
        guard isStreaming else { return }
        if let sample, let pixels = CMSampleBufferGetImageBuffer(sample) {
            SharedFrame.shared.store(pixels)
        }
        if hasMore {
            consumeLoop()
        } else {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                self?.consumeLoop()
            }
        }
    }
}

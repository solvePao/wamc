import Foundation
import CoreMediaIO
import CoreVideo
import OSLog

private func makeFormat() -> CMIOExtensionStreamFormat? {
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: CMVideoCodecType(0x4247_5241), // 'BGRA'
        width: 1920, height: 1080, extensions: nil,
        formatDescriptionOut: &description)
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

private func makeSample(from pixelBuffer: CVPixelBuffer,
                        format: CMFormatDescription?,
                        hostTime: CMTime) -> CMSampleBuffer? {
    var resolved = format
    if resolved == nil {
        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &created)
        guard status == noErr else {
            ExtensionLogger.runtime.error("Creating camera image format failed with OSStatus \(status, privacy: .public)")
            return nil
        }
        resolved = created
    }
    guard let resolved else { return nil }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: hostTime,
        decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: resolved,
        sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr else {
        ExtensionLogger.runtime.error("Creating camera sample buffer failed with OSStatus \(status, privacy: .public)")
        return nil
    }
    return sample
}

private let cachedPlaceholder: CVPixelBuffer? = {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                             &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 24, CVPixelBufferGetDataSize(buffer)) // "waiting for phone" slate
    }
    return buffer
}()

protocol CameraFrameProviding {
    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer?
}

protocol ExtensionSamplePublishing: AnyObject {
    func send(_ sample: CMSampleBuffer, hostTimeNanoseconds: UInt64)
}

struct SharedCameraFrameProvider: CameraFrameProviding {
    private let sharedFrame: SharedFrame

    init(sharedFrame: SharedFrame = .shared) { self.sharedFrame = sharedFrame }

    func sample(format: CMFormatDescription?, hostTime: CMTime) -> CMSampleBuffer? {
        let pixels = sharedFrame.latestFresh(within: 1.0) ?? cachedPlaceholder
        guard let pixels else { return nil }
        return makeSample(from: pixels, format: format, hostTime: hostTime)
    }
}

private final class CMIOExtensionSamplePublisher: ExtensionSamplePublishing {
    weak var stream: CMIOExtensionStream?
    init(stream: CMIOExtensionStream) { self.stream = stream }

    func send(_ sample: CMSampleBuffer, hostTimeNanoseconds: UInt64) {
        stream?.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTimeNanoseconds)
    }
}

/// Publishes the latest sink frame (or placeholder) at 30 FPS to meeting apps.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    var stream: CMIOExtensionStream? {
        didSet { publisher = stream.map(CMIOExtensionSamplePublisher.init(stream:)) }
    }
    private var timer: DispatchSourceTimer?
    private var streamingClients = 0
    private let queue = DispatchQueue(label: "awc.source")
    private let format = makeFormat()
    private let frameProvider: CameraFrameProviding
    private var publisher: ExtensionSamplePublishing?

    init(localizedName: String) {
        frameProvider = SharedCameraFrameProvider()
        super.init()
    }

    init(localizedName: String, frameProvider: CameraFrameProviding,
         publisher: ExtensionSamplePublishing? = nil) {
        self.frameProvider = frameProvider
        self.publisher = publisher
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
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
        timer.resume()
        self.timer = timer
    }

    func stopStream() throws {
        guard streamingClients > 0 else { return }
        streamingClients -= 1
        guard streamingClients == 0 else { return }
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

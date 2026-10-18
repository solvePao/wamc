import AndroidWebcamCore
import CoreImage
import Foundation
import SwiftUI
import AVFoundation
import CoreMediaIO

func makeImageSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &format) == noErr, let format else { return nil }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        dataReady: true, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format, sampleTiming: &timing,
        sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

/// Renders decoded frames into an AVSampleBufferDisplayLayer.
/// Takes the already-wrapped sample: the caller wraps once per frame and
/// shares it with the extension bridge.
final class PreviewRenderer {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.08, alpha: 1)
    }

    func clear() { layer.flushAndRemoveImage() }

    func enqueue(_ sample: CMSampleBuffer) {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        layer.enqueue(sample)
    }
}

private let bridgeRenderContext = CIContext(options: [.useSoftwareRenderer: false])

/// Normalizes a decoded frame to the fixed virtual-camera format.
/// Pass-through at 1920×1080; anything else is aspect-fit letterboxed so the
/// sink always receives the size its format description promises.
func normalizedBridgePixels(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
    let srcW = CVPixelBufferGetWidth(pixelBuffer)
    let srcH = CVPixelBufferGetHeight(pixelBuffer)
    guard BridgeFormat.needsNormalization(srcWidth: srcW, srcHeight: srcH)
            || CVPixelBufferGetIOSurface(pixelBuffer) == nil else {
        return pixelBuffer
    }
    var dst: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, BridgeFormat.width, BridgeFormat.height,
                              kCVPixelFormatType_32BGRA,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                              &dst) == kCVReturnSuccess,
          let dst else { return pixelBuffer }
    CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(dst, []) }
    if let base = CVPixelBufferGetBaseAddress(dst) {
        memset(base, 24, CVPixelBufferGetDataSize(dst))
    }
    let rect = BridgeFormat.fitRect(srcWidth: srcW, srcHeight: srcH)
    guard rect != .zero else { return dst }
    let scale = rect.width / CGFloat(srcW)
    let image = CIImage(cvPixelBuffer: pixelBuffer)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    bridgeRenderContext.render(image, to: dst)
    return dst
}

struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = renderer.layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        // A disconnected or closed preview must not retain the previous feed.
        // The virtual-camera bridge owns its own samples and keeps running.
        (view.layer as? AVSampleBufferDisplayLayer)?.flushAndRemoveImage()
    }
}

enum ExtensionSinkEnqueueResult {
    case accepted
    case full
    case unavailable
    case failed
}

protocol ExtensionFrameSink: AnyObject {
    var available: Bool { get }
    var connectedStreamName: String? { get }
    func discover()
    func enqueue(_ sample: CMSampleBuffer) -> ExtensionSinkEnqueueResult
    func disconnect()
}

/// Forwards frames to the virtual camera extension's sink stream (Phase 2).
/// No-ops gracefully until the extension is installed and approved.
final class ExtensionBridge {
    private let sink: ExtensionFrameSink
    private let now: () -> TimeInterval
    private var fullQueueSince: TimeInterval?
    private var lastDiscoveryAttempt: TimeInterval = 0
    private(set) var lastEnqueuedAt: TimeInterval?

    var available: Bool { sink.available }
    var connectedStreamName: String? { sink.connectedStreamName }

    init(sink: ExtensionFrameSink = CoreMediaIOExtensionSink(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.now = now
        sink.discover()
    }

    deinit { sink.disconnect() }

    func discoverSink() {
        sink.discover()
    }

    func send(_ sample: CMSampleBuffer) {
        let timestamp = now()
        if !sink.available, timestamp - lastDiscoveryAttempt > 2.0 {
            lastDiscoveryAttempt = timestamp
            sink.discover()
        }
        guard sink.available else { return }
        switch sink.enqueue(sample) {
        case .accepted:
            fullQueueSince = nil
            lastEnqueuedAt = timestamp
        case .full:
            if let since = fullQueueSince, timestamp - since > 1.0 {
                sink.disconnect()
                fullQueueSince = nil
                lastEnqueuedAt = nil
                lastDiscoveryAttempt = 0
            } else if fullQueueSince == nil {
                fullQueueSince = timestamp
            }
        case .unavailable:
            break
        case .failed:
            break
        }
    }
}

/// Native stream operations stay at one boundary so queue ownership is testable.
struct CoreMediaIOStreamAccess {
    var copyQueue = CMIOStreamCopyBufferQueue
    var start = CMIODeviceStartStream
    var stop = CMIODeviceStopStream
    var enqueue = CMSimpleQueueEnqueue
}

/// CoreMediaIO owns the system stream and queue; the bridge owns retry policy.
final class CoreMediaIOExtensionSink: ExtensionFrameSink {
    private let reader: CoreMediaIOPropertyReading
    private let streams: CoreMediaIOStreamAccess
    private var bufferQueue: CMSimpleQueue?
    private var sinkDevice: CMIOObjectID?
    private var sinkStream: CMIOStreamID?
    private(set) var available = false
    private(set) var connectedStreamName: String?

    init(reader: CoreMediaIOPropertyReading = CoreMediaIOSystemPropertyReader(),
         streams: CoreMediaIOStreamAccess = CoreMediaIOStreamAccess()) {
        self.reader = reader
        self.streams = streams
    }

    func discover() {
        guard !available else { return }
        // Enumerate CMIO devices -> streams; only sink streams hand out a
        // buffer queue via CMIOStreamCopyBufferQueue, so success = found.
        guard let devices = try? reader.objects(for: UInt32(kCMIOObjectSystemObject),
                                               selector: UInt32(kCMIOHardwarePropertyDevices)) else { return }
        for device in devices {
            guard let streamIDs = try? reader.objects(for: device,
                                                      selector: UInt32(kCMIODevicePropertyStreams)) else { continue }
            for stream in streamIDs {
                // Only our own extension's sink may take the feed. Another
                // virtual camera's sink (e.g. OBS) also matches "sink" and
                // would steal every frame, leaving FaceTime on the slate.
                guard let name = try? reader.string(for: stream, selector: UInt32(kCMIOObjectPropertyName)),
                      name.localizedCaseInsensitiveContains("sink"),
                      name.localizedCaseInsensitiveContains("Android Camera") else { continue }
                let queueAlteredProc: CMIODeviceStreamQueueAlteredProc = { (_, _, _) in }
                var unmanaged: Unmanaged<CMSimpleQueue>?
                if streams.copyQueue(CMIOStreamID(stream), queueAlteredProc, nil, &unmanaged) == noErr,
                   let unmanaged {
                    let queue = unmanaged.takeRetainedValue()
                    guard streams.start(device, stream) == noErr else { continue }
                    bufferQueue = queue
                    sinkDevice = device
                    sinkStream = stream
                    available = true
                    connectedStreamName = name
                    return
                }
            }
        }
    }

    func enqueue(_ sample: CMSampleBuffer) -> ExtensionSinkEnqueueResult {
        guard available, let bufferQueue else { return .unavailable }
        guard CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else {
            return .full
        }
        let retained = Unmanaged.passRetained(sample)
        if streams.enqueue(bufferQueue, retained.toOpaque()) != noErr {
            retained.release()
            return .failed
        }
        return .accepted
    }

    func disconnect() {
        if let sinkDevice, let sinkStream {
            _ = streams.stop(sinkDevice, sinkStream)
        }
        bufferQueue = nil
        sinkDevice = nil
        sinkStream = nil
        available = false
        connectedStreamName = nil
    }
}

/// Dark placeholder published while no phone is streaming.
enum PlaceholderFrame {
    static func make(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 24, CVPixelBufferGetDataSize(buffer))
        }
        return buffer
    }
}

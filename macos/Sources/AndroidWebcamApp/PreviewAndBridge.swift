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

/// Renders decoded CVPixelBuffers into an AVSampleBufferDisplayLayer.
final class PreviewRenderer {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.08, alpha: 1)
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData,
              let sample = makeImageSampleBuffer(pixelBuffer) else { return }
        layer.enqueue(sample)
    }
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
}

/// Forwards frames to the virtual camera extension's sink stream (Phase 2).
/// No-ops gracefully until the extension is installed and approved.
final class ExtensionBridge {
    private var bufferQueue: CMSimpleQueue?
    private(set) var available = false

    private var lastDiscoveryAttempt: TimeInterval = 0

    init() { discoverSink() }

    private(set) var connectedStreamName: String?

    func discoverSink() {
        // Enumerate CMIO devices -> streams; only sink streams hand out a
        // buffer queue via CMIOStreamCopyBufferQueue, so success = found.
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size,
            &size, &devices) == noErr else { return }
        for device in devices {
            var streamAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var streamSize: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }
            var streams = [CMIOObjectID](repeating: 0,
                                         count: Int(streamSize) / MemoryLayout<CMIOObjectID>.size)
            guard CMIOObjectGetPropertyData(device, &streamAddress, 0, nil, streamSize,
                                            &streamSize, &streams) == noErr else { continue }
            for stream in streams {
                guard let name = streamName(stream),
                      name.localizedCaseInsensitiveContains("sink") else { continue }
                let queueAlteredProc: CMIODeviceStreamQueueAlteredProc = { (_, _, _) in }
                _ = CMIODeviceStartStream(device, stream)
                var unmanaged: Unmanaged<CMSimpleQueue>?
                if CMIOStreamCopyBufferQueue(CMIOStreamID(stream), queueAlteredProc, nil, &unmanaged) == noErr,
                   let unmanaged {
                    bufferQueue = unmanaged.takeRetainedValue()
                    available = true
                    connectedStreamName = name
                    return
                }
            }
        }
    }

    private func streamName(_ stream: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(stream, &address, 0, nil,
                                        UInt32(MemoryLayout<CFString>.size),
                                        &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        if !available || bufferQueue == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDiscoveryAttempt > 2.0 {
                lastDiscoveryAttempt = now
                discoverSink()
            }
        }
        guard available, let bufferQueue,
              let sample = makeImageSampleBuffer(pixelBuffer) else { return }
        if CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) {
            CMSimpleQueueEnqueue(bufferQueue, element: Unmanaged.passRetained(sample).toOpaque())
        }
    }
}

/// Dark placeholder published while no phone is streaming.
enum PlaceholderFrame {
    static func make(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  nil, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 24, CVPixelBufferGetDataSize(buffer))
        }
        return buffer
    }
}

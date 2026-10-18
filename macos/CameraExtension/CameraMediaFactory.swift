import CoreMedia
import CoreVideo

/// Separates OS allocation from stream policy so allocation failures stay testable.
protocol CameraMediaCreating {
    func streamFormat() -> (OSStatus, CMVideoFormatDescription?)
    func imageFormat(_ pixels: CVPixelBuffer) -> (OSStatus, CMVideoFormatDescription?)
    func sampleBuffer(_ pixels: CVPixelBuffer, format: CMFormatDescription,
                      hostTime: CMTime) -> (OSStatus, CMSampleBuffer?)
    func placeholderBuffer() -> (CVReturn, CVPixelBuffer?)
}

struct CameraMediaFactory: CameraMediaCreating {
    func streamFormat() -> (OSStatus, CMVideoFormatDescription?) {
        let (status, pixels) = placeholderBuffer()
        guard status == kCVReturnSuccess, let pixels else { return (status, nil) }
        return imageFormat(pixels)
    }

    func imageFormat(_ pixels: CVPixelBuffer) -> (OSStatus, CMVideoFormatDescription?) {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description)
        return (status, description)
    }

    func sampleBuffer(_ pixels: CVPixelBuffer, format: CMFormatDescription,
                      hostTime: CMTime) -> (OSStatus, CMSampleBuffer?) {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        return (status, sample)
    }

    func placeholderBuffer() -> (CVReturn, CVPixelBuffer?) {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return (status, buffer)
    }
}

import Foundation
import CoreImage
import CoreVideo

/// Rotates decoded frames by quarter-turns so a Rotate tap on the phone
/// shows up identically in the Mac preview and the virtual camera.
public enum FrameRotation {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    public static func rotate(_ pixelBuffer: CVPixelBuffer, quarterTurns: Int) -> CVPixelBuffer {
        let turns = quarterTurns & 3
        guard turns != 0 else { return pixelBuffer }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let swapsAxes = turns % 2 == 1
        let outWidth = swapsAxes ? height : width
        let outHeight = swapsAxes ? width : height

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        // CIImage origin is bottom-left; rotate about the centre, then
        // translate the result back into positive coordinates.
        let angle = CGFloat(turns) * .pi / 2
        image = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        let bounds = image.extent
        image = image.transformed(by: CGAffineTransform(
            translationX: -bounds.minX, y: -bounds.minY))

        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, outWidth, outHeight,
                                  kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess,
              let output else { return pixelBuffer }
        context.render(image, to: output)
        return output
    }
}

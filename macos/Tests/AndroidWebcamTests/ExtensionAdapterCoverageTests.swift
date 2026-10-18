import AndroidWebcamCore
import CoreMedia
import CoreMediaIO
import XCTest
@testable import CameraExtensionRuntime

final class ExtensionAdapterCoverageTests: XCTestCase {
    func testReadOnlyPropertySettersAcceptEmptyChanges() throws {
        let source = SourceStreamSource(localizedName: "test")
        let sink = SinkStreamSource(localizedName: "test")
        try source.setStreamProperties(CMIOExtensionStreamProperties(dictionary: [:]))
        try sink.setStreamProperties(CMIOExtensionStreamProperties(dictionary: [:]))
        let device = DeviceSource(localizedName: "test")
        try device.setDeviceProperties(CMIOExtensionDeviceProperties(dictionary: [:]))
    }
}

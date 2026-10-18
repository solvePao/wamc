#if WAMC_COVERAGE_TESTING
import AndroidWebcamCore
#endif
import Foundation
import CoreMediaIO

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    static let sourceStreamUUID = UUID(uuidString: "A9E6C9B0-1B2C-4D3E-BF50-8B3E3C7D4E12")!
    static let sinkStreamUUID = UUID(uuidString: "C2B8E5F1-3D4A-4E5B-8F61-9C4D5E6F7A23")!

    private(set) var streams: [CMIOExtensionStream] = []
    private var sourceStream: SourceStreamSource!
    private var sinkStream: SinkStreamSource!

    init(localizedName: String) {
        super.init()
        sourceStream = SourceStreamSource(localizedName: "Android Camera Video")
        sinkStream = SinkStreamSource(localizedName: "Android Camera Sink")
        
        let source = CMIOExtensionStream(
            localizedName: "Android Camera Video",
            streamID: Self.sourceStreamUUID,
            direction: .source,
            clockType: .hostTime,
            source: sourceStream)
        let sink = CMIOExtensionStream(
            localizedName: "Android Camera Sink",
            streamID: Self.sinkStreamUUID,
            direction: .sink,
            clockType: .hostTime,
            source: sinkStream)
        streams = [source, sink]
        sourceStream.stream = source
        sinkStream.stream = sink
    }

    private let healthProperty = CMIOExtensionProperty(rawValue: CameraHealthSnapshot.propertyName)
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel, healthProperty] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            props.model = "Android Camera"
        }
        if properties.contains(healthProperty) {
            let data = try JSONEncoder().encode(SharedFrame.shared.healthSnapshot())
            let value = String(decoding: data, as: UTF8.self) as NSString
            props.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: value),
                                   forProperty: healthProperty)
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

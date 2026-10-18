import Foundation
import CoreMediaIO

/// Shared latest frame handed from the sink stream to the source stream.
final class SharedFrame {
    static let shared = SharedFrame()
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func store(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); buffer = pixelBuffer; lock.unlock()
    }
    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    static let deviceUUID = UUID(uuidString: "78F8C72B-45F2-4D3B-8C49-623D3F285D9A")!

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!
    private var device: CMIOExtensionDevice!

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = DeviceSource(localizedName: "Android Camera")
        do {
            device = CMIOExtensionDevice(localizedName: "Android Camera",
                                         deviceID: Self.deviceUUID,
                                         legacyDeviceID: nil,
                                         source: deviceSource)
            try provider.addDevice(device)
            for stream in deviceSource.streams {
                try device.addStream(stream)
            }
        } catch {
            NSLog("AndroidCamera extension setup failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer, .providerName] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "Android Webcam"
        }
        if properties.contains(.providerName) {
            props.name = "Android Camera Provider"
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

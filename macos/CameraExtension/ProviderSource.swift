#if WAMC_COVERAGE_TESTING
import AndroidWebcamCore
#endif
import Foundation
import CoreMediaIO
import OSLog

/// Shared latest frame handed from the sink stream to the source stream.
/// Timestamped so the source publishes the waiting slate instead of a frozen
/// frame when the phone stops delivering (restart, stall, unplug).
final class SharedFrame {
    static let shared = SharedFrame()
    private let lock = NSLock()
    private let now: () -> Date
    private var buffer: CVPixelBuffer?
    private var storedAt = Date.distantPast
    private let instanceID = UUID().uuidString
    private var sinkSequence: UInt64 = 0
    private var sinkReceivedAt: TimeInterval = 0
    private var sourceSequence: UInt64 = 0
    private var sourcePublishedAt: TimeInterval = 0

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func store(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        buffer = pixelBuffer
        storedAt = now()
        sinkSequence &+= 1
        sinkReceivedAt = ProcessInfo.processInfo.systemUptime
    }
    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
    func latestFresh(within interval: TimeInterval) -> CVPixelBuffer? {
        freshFrame(within: interval)?.pixels
    }
    func freshFrame(within interval: TimeInterval) -> (pixels: CVPixelBuffer, sequence: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer, now().timeIntervalSince(storedAt) <= interval else { return nil }
        return (buffer, sinkSequence)
    }
    func notePublished(sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        sourceSequence = sequence
        sourcePublishedAt = ProcessInfo.processInfo.systemUptime
    }
    func healthSnapshot() -> CameraHealthSnapshot {
        lock.lock(); defer { lock.unlock() }
        return CameraHealthSnapshot(instanceID: instanceID, sinkSequence: sinkSequence,
            sinkReceivedAt: sinkReceivedAt, sourceSequence: sourceSequence,
            sourcePublishedAt: sourcePublishedAt)
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    static let deviceUUID = UUID(uuidString: "78F8C72B-45F2-4D3B-8C49-623D3F285D9A")!

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!
    private var device: CMIOExtensionDevice!
    private var healthTimer: DispatchSourceTimer?

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
            // CoreMediaIO caches custom properties in camera clients. Publish
            // changes so readback checks see current frame counters and times.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                guard let self,
                      let properties = try? self.deviceSource.deviceProperties(
                        forProperties: [CMIOExtensionProperty(rawValue: CameraHealthSnapshot.propertyName)]) else { return }
                self.device.notifyPropertiesChanged(properties.propertiesDictionary)
            }
            timer.resume()
            healthTimer = timer
        } catch {
            ExtensionLogger.runtime.fault("Camera extension provider setup failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    deinit { healthTimer?.cancel() }

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

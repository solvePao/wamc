import Foundation
import CoreMediaIO
import OSLog

struct CameraDeviceSnapshot: Equatable {
    let uid: String
    let streamNames: [String]
}

protocol CameraDeviceQuery {
    func devices() throws -> [CameraDeviceSnapshot]
}

/// Match our stable device identity; an OBS sink is not a WAMC device.
enum VirtualCameraDevice {
    static let uid = "78F8C72B-45F2-4D3B-8C49-623D3F285D9A"
    static let sinkName = "Android Camera Sink"

    static func sinkIsRegistered() -> Bool {
        sinkIsRegistered(using: CoreMediaIODeviceQuery())
    }

    static func sinkIsRegistered(using query: CameraDeviceQuery) -> Bool {
        do {
            return try query.devices().contains {
                $0.uid == uid && $0.streamNames.contains(sinkName)
            }
        } catch {
            AppLogger.setup.warning("Could not inspect CoreMediaIO camera devices: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

protocol CoreMediaIOPropertyReading {
    func objects(for object: UInt32, selector: UInt32) throws -> [UInt32]
    func string(for object: UInt32, selector: UInt32) throws -> String?
}

struct CoreMediaIODeviceQuery: CameraDeviceQuery {
    private let reader: CoreMediaIOPropertyReading

    init(reader: CoreMediaIOPropertyReading = CoreMediaIOSystemPropertyReader()) {
        self.reader = reader
    }

    func devices() throws -> [CameraDeviceSnapshot] {
        let system = UInt32(kCMIOObjectSystemObject)
        let ids = try reader.objects(for: system, selector: UInt32(kCMIOHardwarePropertyDevices))
        return try ids.compactMap { device in
            guard let uid = try reader.string(for: device, selector: UInt32(kCMIODevicePropertyDeviceUID)) else {
                return nil
            }
            let streams = try reader.objects(for: device, selector: UInt32(kCMIODevicePropertyStreams))
            let names = try streams.compactMap { stream in
                try reader.string(for: stream, selector: UInt32(kCMIOObjectPropertyName))
            }
            return CameraDeviceSnapshot(uid: uid, streamNames: names)
        }
    }
}

private struct CoreMediaIOSystemPropertyReader: CoreMediaIOPropertyReading {
    func objects(for object: UInt32, selector: UInt32) throws -> [UInt32] {
        try readObjects(CMIOObjectID(object), selector: selector).map { UInt32($0) }
    }

    func string(for object: UInt32, selector: UInt32) throws -> String? {
        try readString(CMIOObjectID(object), selector: selector)
    }

    private func readObjects(_ object: CMIOObjectID, selector: UInt32) throws -> [CMIOObjectID] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw CoreMediaIOQueryError(status: sizeStatus) }
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }
        var values = [CMIOObjectID](repeating: 0, count: count)
        let readStatus = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &values)
        guard readStatus == noErr else { throw CoreMediaIOQueryError(status: readStatus) }
        return values
    }

    private func readString(_ object: CMIOObjectID, selector: UInt32) throws -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &value)
        guard status == noErr else { throw CoreMediaIOQueryError(status: status) }
        return value?.takeRetainedValue() as String?
    }

    private func propertyAddress(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
}

private struct CoreMediaIOQueryError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "CoreMediaIO property query failed with OSStatus \(status)." }
}

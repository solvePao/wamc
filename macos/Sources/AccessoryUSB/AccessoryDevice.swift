import CLibusb
import Foundation

public struct AccessoryDevice: Equatable, Sendable {
    /// USB topology survives the phone's transition into accessory mode.
    public let id: String
    public let name: String

    public static func discover() -> [AccessoryDevice] {
        guard let context = USBContext.shared else { return [] }
        return context.devices().compactMap { device in
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device.pointer, &descriptor) == 0,
                  descriptor.idVendor == 0x04e8 || Self.isAccessory(descriptor) else { return nil }
            return AccessoryDevice(id: topology(device.pointer),
                                   name: descriptor.idVendor == 0x04e8 ? "Samsung phone" : "Android accessory")
        }
    }

    static func isAccessory(_ descriptor: libusb_device_descriptor) -> Bool {
        descriptor.idVendor == 0x18d1 && [0x2d00, 0x2d01].contains(descriptor.idProduct)
    }

    static func topology(_ device: OpaquePointer) -> String {
        var ports = [UInt8](repeating: 0, count: 8)
        let count = libusb_get_port_numbers(device, &ports, Int32(ports.count))
        let path = count > 0 ? ports.prefix(Int(count)).map(String.init).joined(separator: ".") : "unknown"
        return "\(libusb_get_bus_number(device)).\(path)"
    }
}

public enum AccessoryUSBError: LocalizedError {
    case unavailable(String)
    case transfer(Int32)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .transfer(let code):
            return "USB access failed (\(String(cString: libusb_error_name(code)))). Close other phone utilities or use Wi-Fi/hotspot."
        }
    }
}

/// One process-wide Darwin context avoids hotplug-thread teardown while a
/// concurrent discovery/setup operation initializes another libusb context.
final class USBContext {
    static let shared = try? USBContext()
    let pointer: OpaquePointer
    private init() throws {
        var context: OpaquePointer?
        let result = libusb_init(&context)
        guard result == 0, let context else { throw AccessoryUSBError.transfer(result) }
        pointer = context
    }
    func devices() -> [USBDevice] {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(pointer, &list)
        guard count >= 0, let list else { return [] }
        defer { libusb_free_device_list(list, 1) }
        return (0..<Int(count)).compactMap { index in
            list[index].map(USBDevice.init)
        }
    }
    deinit { libusb_exit(pointer) }
}

/// Owns a reference independent of the temporary enumeration list.
final class USBDevice {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) {
        self.pointer = libusb_ref_device(pointer)
    }
    deinit { libusb_unref_device(pointer) }
}

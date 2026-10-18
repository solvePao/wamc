import CLibusb
import Foundation
import OSLog

/// Owns one accessory interface. No driver capture, elevated helper, or ADB.
public final class AccessorySession: @unchecked Sendable {
    private let context: USBContext
    private let cancelled: () -> Bool
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var interface: Int32 = -1
    private var input: UInt8 = 0
    private var output: UInt8 = 0
    public let deviceID: String

    public init(deviceID: String?, cancelled: @escaping () -> Bool) throws {
        self.cancelled = cancelled
        guard let sharedContext = USBContext.shared else {
            throw AccessoryUSBError.unavailable("USB discovery is unavailable. Use Wi-Fi/hotspot.")
        }
        context = sharedContext
        guard let original = context.devices().first(where: {
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor($0.pointer, &descriptor) == 0 else { return false }
            return (descriptor.idVendor == 0x04e8 || AccessoryDevice.isAccessory(descriptor))
                && (deviceID == nil || AccessoryDevice.topology($0.pointer) == deviceID)
        }) else {
            throw AccessoryUSBError.unavailable("No supported USB phone found. Connect a data cable, open WAMC on Android, or use Wi-Fi/hotspot.")
        }
        self.deviceID = AccessoryDevice.topology(original.pointer)
        do {
            try open(original.pointer)
            var descriptor = libusb_device_descriptor()
            try check(libusb_get_device_descriptor(original.pointer, &descriptor))
            if !AccessoryDevice.isAccessory(descriptor) {
                try negotiate()
                closeHandle()
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                var accessory: USBDevice?
                while !cancelled(), ProcessInfo.processInfo.systemUptime < deadline {
                    accessory = context.devices().first { device in
                        var d = libusb_device_descriptor()
                        return libusb_get_device_descriptor(device.pointer, &d) == 0
                            && AccessoryDevice.isAccessory(d)
                            && AccessoryDevice.topology(device.pointer) == self.deviceID
                    }
                    if accessory != nil { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard !cancelled(), let accessory else {
                    throw AccessoryUSBError.unavailable("The phone did not enter USB accessory mode. Unlock it, open WAMC and retry, or use Wi-Fi/hotspot.")
                }
                try open(accessory.pointer)
            }
            guard !cancelled(), let handle else {
                throw AccessoryUSBError.unavailable("USB setup cancelled.")
            }
            try claim(libusb_get_device(handle))
        } catch {
            closeHandle()
            throw error
        }
    }

    public func read() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw AccessoryUSBError.unavailable("USB disconnected.") }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var transferred: Int32 = 0
        let result = libusb_bulk_transfer(handle, input, &bytes, Int32(bytes.count), &transferred, 100)
        // A timeout may still carry a partial transfer, which must reach the parser.
        if result != Int32(LIBUSB_ERROR_TIMEOUT.rawValue) { try check(result) }
        return Data(bytes.prefix(Int(transferred)))
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw AccessoryUSBError.unavailable("USB disconnected.") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while offset < data.count {
                guard !cancelled() else { throw AccessoryUSBError.unavailable("USB write cancelled.") }
                var transferred: Int32 = 0
                let count = min(data.count - offset, 16_384)
                let result = libusb_bulk_transfer(handle, output,
                    UnsafeMutablePointer(mutating: base.advanced(by: offset)), Int32(count), &transferred, 250)
                if result == Int32(LIBUSB_ERROR_TIMEOUT.rawValue), ProcessInfo.processInfo.systemUptime < deadline {
                    // USB permission can be approved after the interface appears.
                    // Retain any partial progress rather than retransmitting bytes.
                    offset += Int(transferred)
                    continue
                }
                try check(result)
                guard transferred > 0 else { throw AccessoryUSBError.unavailable("USB write made no progress.") }
                offset += Int(transferred)
            }
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeHandle()
    }

    private func open(_ device: OpaquePointer) throws {
        try check(libusb_open(device, &handle))
    }

    private func negotiate() throws {
        guard let handle else { return }
        var version = [UInt8](repeating: 0, count: 2)
        try checkCancellation()
        let result = libusb_control_transfer(handle, 0xc0, 51, 0, 0, &version, 2, 500)
        guard result == 2, version[0] != 0 || version[1] != 0 else {
            throw AccessoryUSBError.unavailable("This phone did not accept Android Open Accessory. Try File transfer in its USB settings, or use Wi-Fi/hotspot on unsupported firmware.")
        }
        let strings = ["WAMC", "Wired Android Mac Camera", "WAMC video stream", "1.0", "https://github.com/solvePao/wamc", "WAMC"]
        for (index, string) in strings.enumerated() {
            try checkCancellation()
            var bytes = Array(string.utf8) + [0]
            try check(libusb_control_transfer(handle, 0x40, 52, 0, UInt16(index), &bytes, UInt16(bytes.count), 500))
        }
        try checkCancellation()
        try check(libusb_control_transfer(handle, 0x40, 53, 0, 0, nil, 0, 500))
    }

    private func claim(_ device: OpaquePointer?) throws {
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        try check(libusb_get_active_config_descriptor(device, &config))
        guard let config else { throw AccessoryUSBError.unavailable("USB configuration unavailable.") }
        defer { libusb_free_config_descriptor(config) }
        for i in 0..<Int(config.pointee.bNumInterfaces) {
            let item = config.pointee.interface[i]
            for j in 0..<Int(item.num_altsetting) {
                let alt = item.altsetting[j]
                // Never claim the separate ADB interface (ff/42/01).
                guard alt.bInterfaceClass == 0xff, alt.bInterfaceSubClass == 0xff,
                      alt.bInterfaceProtocol == 0 else { continue }
                var read: UInt8 = 0, write: UInt8 = 0
                for k in 0..<Int(alt.bNumEndpoints) {
                    let endpoint = alt.endpoint[k]
                    guard endpoint.bmAttributes & 3 == 2 else { continue }
                    if endpoint.bEndpointAddress & 0x80 != 0 { read = endpoint.bEndpointAddress }
                    else { write = endpoint.bEndpointAddress }
                }
                guard read != 0, write != 0, let handle else { continue }
                try check(libusb_claim_interface(handle, Int32(alt.bInterfaceNumber)))
                interface = Int32(alt.bInterfaceNumber)
                if alt.bAlternateSetting != 0 {
                    try check(libusb_set_interface_alt_setting(handle, interface, Int32(alt.bAlternateSetting)))
                }
                input = read; output = write
                return
            }
        }
        throw AccessoryUSBError.unavailable("No accessible USB accessory video interface. Use Wi-Fi/hotspot on this phone.")
    }

    private func closeHandle() {
        if let handle {
            if interface >= 0 { _ = libusb_release_interface(handle, interface) }
            libusb_close(handle)
        }
        handle = nil; interface = -1
    }
    private func checkCancellation() throws {
        if cancelled() { throw AccessoryUSBError.unavailable("USB setup cancelled.") }
    }

    private func check(_ result: Int32) throws {
        if result < 0 {
            Logger(subsystem: "com.androidwebcam.app", category: "usb").error("USB operation failed, code \(result, privacy: .public)")
            throw AccessoryUSBError.transfer(result)
        }
    }
    deinit { closeHandle() }
}

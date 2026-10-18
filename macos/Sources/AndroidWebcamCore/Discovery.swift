import Foundation

/// Bonjour discovery contract shared with the Android advertiser.
/// See shared/protocol/PROTOCOL.md "Discovery (Bonjour)".
public enum WamcDiscovery {
    public static let serviceType = "_wamc._tcp"
    public static let servicePort = 27183
    public static let protocolVersion = 2

    public static func shortId(_ id: String) -> String {
        let alnum = id.filter { $0.isLetter || $0.isNumber }
        return String(alnum.prefix(4)).lowercased().ifEmptyFallback("0000")
    }

    public static func isValidId(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

private extension String {
    func ifEmptyFallback(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// A phone found via Bonjour, parsed from its TXT record.
/// The network endpoint itself stays in the app layer (`NWEndpoint`);
/// this value is pure and unit-tested.
public struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    public var id: String
    public var instanceName: String
    public var model: String
    public var brand: String
    public var sdk: Int?
    public var port: Int
    public var version: Int
    public var emulator: Bool?

    public init(id: String, instanceName: String, model: String, brand: String,
                sdk: Int?, port: Int, version: Int, emulator: Bool? = nil) {
        self.id = id
        self.instanceName = instanceName
        self.model = model
        self.brand = brand
        self.sdk = sdk
        self.port = port
        self.version = version
        self.emulator = emulator
    }

    public var isEmulator: Bool {
        if let emulator { return emulator }
        let model = model.lowercased().replacingOccurrences(of: "_", with: " ")
        return model.hasPrefix("sdk gphone") || model == "google sdk"
            || model.hasPrefix("android sdk built for")
    }

    public var displayName: String {
        model.isEmpty ? instanceName : "\(model) · \(WamcDiscovery.shortId(id))"
    }

    /// Parses TXT entries. Returns nil without a valid stable `id`.
    public static func parseTXT(_ entries: [String: String], instanceName: String) -> DiscoveredDevice? {
        guard let id = entries["id"], WamcDiscovery.isValidId(id) else { return nil }
        let version = entries["v"].flatMap(Int.init) ?? 1
        let port = entries["port"].flatMap(Int.init) ?? WamcDiscovery.servicePort
        guard (1...65535).contains(port) else { return nil }
        return DiscoveredDevice(
            id: id,
            instanceName: instanceName,
            model: entries["model"] ?? "",
            brand: entries["brand"] ?? "",
            sdk: entries["sdk"].flatMap(Int.init),
            port: port,
            version: version,
            emulator: entries["emulator"].flatMap { value in
                switch value {
                case "0": return false
                case "1": return true
                default: return nil
                }
            })
    }
}

/// Parses `adb devices -l` output. Columns are space-padded (some adb
/// builds use tabs): `RZCT40TFK9D            device usb:... model:SM_E236B`.
public enum AdbDeviceList {
    public static func parse(_ output: String) -> [(serial: String, state: String, model: String)] {
        parseDetailed(output).map { (serial: $0.serial, state: $0.state, model: $0.model) }
    }

    public static func parseDetailed(_ output: String) -> [AdbDevice] {
        output.split(separator: "\n").compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard tokens.count >= 2, tokens[0] != "List" else { return nil }
            let model = tokens.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
                ?? "Android device"
            let usbPath = tokens.first(where: { $0.hasPrefix("usb:") })
                .map { String($0.dropFirst(4)) }
            return AdbDevice(serial: tokens[0], state: tokens[1], model: model, usbPath: usbPath)
        }
    }
}

public struct AdbDevice: Equatable {
    public var serial: String
    public var state: String
    public var model: String
    public var usbPath: String?

    public var isPhysicalUSB: Bool {
        usbPath?.isEmpty == false && !serial.hasPrefix("emulator-")
            && !serial.contains(":") && !serial.hasSuffix("._adb-tls-connect._tcp")
    }
}

/// Pure trust decisions. Persistence (UserDefaults) lives in the app layer.
public struct TrustedDevices: Equatable {
    public private(set) var trustedIds: Set<String>
    public init(trustedIds: Set<String> = []) { self.trustedIds = trustedIds }
    public func isTrusted(_ id: String) -> Bool { trustedIds.contains(id) }
    public mutating func trust(_ id: String) { trustedIds.insert(id) }
    public mutating func untrust(_ id: String) { trustedIds.remove(id) }
}

public enum TransportKind: String, Equatable {
    case usb, wifi
}

/// Pure transport arbitration: USB wins, one active connection,
/// Wi-Fi auto-connect only for trusted devices. Mirrors AutoStartPolicy style.
public struct ConnectionPolicy {
    public init() {}

    public func preferredTransport(usbPresent: Bool, trustedWifiAvailable: Bool) -> TransportKind? {
        if usbPresent { return .usb }
        if trustedWifiAvailable { return .wifi }
        return nil
    }

    /// Switch to USB whenever it appears and we are on Wi-Fi (or idle).
    public func shouldSwitchToUSB(active: TransportKind?, usbPresent: Bool) -> Bool {
        usbPresent && active != .usb
    }

    public func shouldAutoConnectWifi(
        device: DiscoveredDevice,
        trusted: Bool,
        active: TransportKind?,
        autoConnect: Bool,
        userStopped: Bool
    ) -> Bool {
        trusted && autoConnect && !userStopped && active == nil
    }

    /// After USB loss, Wi-Fi may take over only for a trusted device.
    public func shouldFallBackToWifi(
        active: TransportKind?,
        usbPresent: Bool,
        trustedWifiAvailable: Bool,
        autoConnect: Bool,
        userStopped: Bool
    ) -> Bool {
        !usbPresent && trustedWifiAvailable && autoConnect && !userStopped && active != .wifi
    }
}

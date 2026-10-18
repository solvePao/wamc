import Foundation
import AVFoundation

struct AndroidDevice: Identifiable, Equatable {
    var id: String // adb serial
    var model: String
    var state: String
}

/// Finds Samsung/Android phones via adb and native UVC webcams via AVFoundation.
enum DeviceDiscovery {

    static func adbPath() -> String? {
        let sdk = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        return FileManager.default.isExecutableFile(atPath: sdk) ? sdk : nil
    }

    static func listAndroidDevices() -> [AndroidDevice] {
        guard let adb = adbPath(), let output = run(adb, ["devices", "-l"]) else { return [] }
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let detail = String(parts[1])
            let model = detail.split(separator: " ")
                .first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
                ?? "Android device"
            let state = detail.split(separator: " ").first.map(String.init) ?? ""
            return AndroidDevice(id: String(parts[0]), model: model, state: state)
        }
    }

    /// `adb forward tcp:27183 tcp:27183`; returns false when adb/phone missing.
    @discardableResult
    static func forwardPort(_ port: Int = 27183) -> Bool {
        guard let adb = adbPath() else { return false }
        return run(adb, ["forward", "tcp:\(port)", "tcp:\(port)"]) != nil
    }

    static func removeForward(_ port: Int = 27183) {
        guard let adb = adbPath() else { return }
        _ = run(adb, ["forward", "--remove", "tcp:\(port)"])
    }

    /// Sets the phone's default USB mode to MTP (Transferring files / Android Auto).
    @discardableResult
    static func configureDefaultUsbMode(serial: String? = nil) -> Bool {
        guard let adb = adbPath() else { return false }
        var prefix = [String]()
        if let serial { prefix = ["-s", serial] }
        _ = run(adb, prefix + ["shell", "svc", "usb", "setScreenUnlockedFunctions", "mtp"])
        _ = run(adb, prefix + ["shell", "svc", "usb", "setFunctions", "mtp"])
        return true
    }

    /// Phones in native UVC webcam mode (Android 14+) appear here directly.
    static func nativeUVCWebcams() -> [String] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video, position: .unspecified).devices.map(\.localizedName)
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        } catch {
            return nil
        }
    }
}

import AndroidWebcamCore
import Foundation
import AVFoundation
import CoreAudio
import OSLog

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
        let candidates = [sdk, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func listAndroidDevices(
        executable: String? = adbPath(),
        command: ((String, [String]) -> String?)? = nil
    ) -> [AndroidDevice] {
        guard let adb = executable,
              let output = (command ?? run)(adb, ["devices", "-l"]) else { return [] }
        return androidDevices(from: output)
    }

    /// Converts adb output to the app's physical USB inventory. Kept separate
    /// from process execution so discovery policy can be verified without adb.
    static func androidDevices(from output: String) -> [AndroidDevice] {
        return AdbDeviceList.parseDetailed(output).filter(\.isPhysicalUSB).map {
            AndroidDevice(id: $0.serial, model: $0.model, state: $0.state)
        }
    }

    /// `adb forward tcp:27183 tcp:27183`; returns false when adb/phone missing.
    @discardableResult
    static func forwardPort(
        _ port: Int = 27183,
        executable: String? = adbPath(),
        command: ((String, [String]) -> String?)? = nil
    ) -> Bool {
        guard let adb = executable else { return false }
        return (command ?? run)(adb, ["forward", "tcp:\(port)", "tcp:\(port)"]) != nil
    }

    static func removeForward(
        _ port: Int = 27183,
        executable: String? = adbPath(),
        command: ((String, [String]) -> String?)? = nil
    ) {
        guard let adb = executable else { return }
        _ = (command ?? run)(adb, ["forward", "--remove", "tcp:\(port)"])
    }

    /// Sets the phone's default USB mode to MTP (Transferring files / Android Auto).
    @discardableResult
    static func configureDefaultUsbMode(
        serial: String? = nil,
        executable: String? = adbPath(),
        command: ((String, [String]) -> String?)? = nil
    ) -> Bool {
        guard let adb = executable else { return false }
        let runCommand = command ?? run
        var prefix = [String]()
        if let serial { prefix = ["-s", serial] }
        let unlocked = runCommand(adb, prefix + ["shell", "svc", "usb", "setScreenUnlockedFunctions", "mtp"])
        let current = runCommand(adb, prefix + ["shell", "svc", "usb", "setFunctions", "mtp"])
        return unlocked != nil && current != nil
    }

    /// Phones in native UVC webcam mode (Android 14+) appear here directly.
    static func nativeUVCWebcams() -> [String] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video, position: .unspecified).devices
            .filter { $0.transportType == Int32(kAudioDeviceTransportTypeUSB) }
            .map(\.localizedName)
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        do {
            return try ADBCommandRunner().run(path, args,
                deadline: ProcessInfo.processInfo.systemUptime + 2)
        } catch {
            AppLogger.discovery.warning("ADB discovery command failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}

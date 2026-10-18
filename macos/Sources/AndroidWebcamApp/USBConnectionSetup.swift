import AndroidWebcamCore
import Darwin
import Foundation

/// Performs one cancellable USB setup on a background queue.
final class USBConnectionSetup: @unchecked Sendable {
    struct PreparedConnection: Sendable {
        let serial: String
        let port: UInt16
        let warnings: [String]
    }

    private let deadline: TimeInterval
    private let commands: ADBCommandExecuting
    private let adbPath: () -> String?

    /// Deadline is absolute system uptime, shared with the connection attempt.
    init(deadline: TimeInterval,
         adbPath: @escaping () -> String? = DeviceDiscovery.adbPath,
         commands: ADBCommandExecuting = ADBCommandRunner()) {
        self.deadline = deadline
        self.adbPath = adbPath
        self.commands = commands
    }

    func cancel() { commands.cancel() }

    func prepare(preferredSerial: String?) throws -> PreparedConnection {
        guard let adb = adbPath() else {
            throw USBSetupError.message("ADB was not found. Install Android platform tools, then reconnect.")
        }
        let output = try commands.run(adb, ["devices", "-l"], deadline: deadline)
        let devices = AdbDeviceList.parseDetailed(output).filter(\.isPhysicalUSB)
        let device: AdbDevice
        if let preferredSerial {
            guard let selected = devices.first(where: { $0.serial == preferredSerial }) else {
                throw USBSetupError.message("The selected USB phone was not found. Check its cable and USB debugging.")
            }
            device = selected
        } else if let authorized = devices.first(where: { $0.state == "device" }) {
            device = authorized
        } else if let unavailable = devices.first {
            device = unavailable
        } else {
            throw USBSetupError.message("No USB phone found. Connect a physical phone and enable USB debugging.")
        }
        switch device.state {
        case "device": break
        case "unauthorized":
            throw USBSetupError.message("Allow USB debugging on \(device.model), then connect again.")
        case "offline":
            throw USBSetupError.message("\(device.model) is offline. Reconnect its USB cable and try again.")
        default:
            throw USBSetupError.message("\(device.model) is unavailable (\(device.state)). Reconnect and try again.")
        }

        let prefix = ["-s", device.serial]
        var warnings: [String] = []
        for operation in ["setScreenUnlockedFunctions", "setFunctions"] {
            do {
                _ = try commands.run(adb, prefix + ["shell", "svc", "usb", operation, "mtp"],
                                     deadline: deadline)
            } catch let error as USBSetupError {
                if case .commandFailed(let detail) = error {
                    warnings.append("USB mode could not be changed: \(detail)")
                } else {
                    throw error
                }
            }
        }

        // Know the port before spawning ADB, so cancellation can always remove
        // a forward even if ADB is interrupted before returning its output.
        let port = try Self.reserveForwardingPort()
        do {
            _ = try commands.run(adb,
                prefix + ["forward", "--no-rebind", "tcp:\(port)", "tcp:27183"], deadline: deadline)
        } catch let error as USBSetupError {
            if case .commandFailed(let detail) = error {
                // --no-rebind can fail because another client owns this port.
                // An explicit rejection never grants us ownership to remove it.
                throw USBSetupError.message("USB forwarding failed: \(detail)")
            }
            Self.removeForward(serial: device.serial, port: port)
            throw error
        } catch {
            Self.removeForward(serial: device.serial, port: port)
            throw error
        }
        return PreparedConnection(serial: device.serial, port: port, warnings: warnings)
    }

    private static func reserveForwardingPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw USBSetupError.message("Could not reserve a local USB forwarding port.")
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw USBSetupError.message("Could not bind a local USB forwarding port.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard found == 0, port > 0 else {
            throw USBSetupError.message("Could not read the local USB forwarding port.")
        }
        return port
    }

    static func removeForward(serial: String, port: UInt16) {
        DispatchQueue.global(qos: .utility).async {
            guard let adb = DeviceDiscovery.adbPath() else { return }
            _ = try? ADBCommandRunner().run(adb,
                ["-s", serial, "forward", "--remove", "tcp:\(port)"],
                deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
    }
}

enum USBSetupError: LocalizedError {
    case cancelled
    case timedOut
    case commandFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "USB connection cancelled."
        case .timedOut: return "USB connection timed out after 5 seconds. Check the phone and try again."
        case .commandFailed(let detail), .message(let detail): return detail
        }
    }
}

/// Shared bounded subprocess execution. File output prevents pipe backpressure deadlocks.
protocol ADBCommandExecuting: Sendable {
    func cancel()
    func run(_ path: String, _ arguments: [String], deadline: TimeInterval) throws -> String
}

final class ADBCommandRunner: ADBCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeProcess: Process?

    func cancel() {
        lock.lock()
        cancelled = true
        let process = activeProcess
        lock.unlock()
        if let process { Self.stop(process) }
    }

    func run(_ path: String, _ arguments: [String], deadline: TimeInterval) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wamc-adb-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw USBSetupError.message("Could not create the ADB output file.")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        lock.lock()
        if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
            let wasCancelled = cancelled
            lock.unlock()
            throw wasCancelled ? USBSetupError.cancelled : USBSetupError.timedOut
        }
        activeProcess = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            activeProcess = nil
            lock.unlock()
            throw error
        }
        defer {
            lock.lock()
            activeProcess = nil
            lock.unlock()
        }
        while process.isRunning {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                Self.stop(process)
                throw wasCancelled ? USBSetupError.cancelled : USBSetupError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let data = try Data(contentsOf: outputURL)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationReason == .uncaughtSignal {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw USBSetupError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw USBSetupError.timedOut }
            throw USBSetupError.message("ADB was interrupted before finishing USB setup.")
        }
        guard process.terminationStatus == 0 else {
            throw USBSetupError.commandFailed(text.isEmpty ? "ADB exited with status \(process.terminationStatus)." : text)
        }
        return text
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

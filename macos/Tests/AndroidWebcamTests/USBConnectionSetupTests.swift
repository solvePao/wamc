import Foundation
import XCTest
@testable import AndroidWebcamAppRuntime

final class USBConnectionSetupTests: XCTestCase {
    private let deviceList = "List of devices attached\nRZ123 device usb:1-1 model:SM_S918B\n"

    func testPrepareSelectsPhysicalDeviceAndCollectsUsbModeWarnings() throws {
        let runner = FakeADBRunner(deviceList: deviceList, failedOperations: ["setScreenUnlockedFunctions", "setFunctions"])
        let setup = makeSetup(runner: runner)

        let prepared = try setup.prepare(preferredSerial: "RZ123")

        XCTAssertEqual(prepared.serial, "RZ123")
        XCTAssertGreaterThan(prepared.port, 0)
        XCTAssertEqual(prepared.warnings.count, 2)
        XCTAssertTrue(runner.calls.contains { $0.contains("forward") && $0.contains("--no-rebind") })
    }

    func testPrepareRejectsMissingAndUnauthorizedDevices() {
        let missing = makeSetup(runner: FakeADBRunner(deviceList: deviceList))
        XCTAssertThrowsError(try missing.prepare(preferredSerial: "OTHER")) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription,
                           "The selected USB phone was not found. Check its cable and USB debugging.")
        }

        let unauthorized = makeSetup(runner: FakeADBRunner(
            deviceList: "PHONE unauthorized usb:1-1 model:SM_TEST\n"))
        XCTAssertThrowsError(try unauthorized.prepare(preferredSerial: nil)) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription,
                           "Allow USB debugging on SM TEST, then connect again.")
        }
    }

    func testPrepareRejectsMissingAdbAndEmptyPhysicalDeviceList() {
        let missingADB = USBConnectionSetup(deadline: ProcessInfo.processInfo.systemUptime + 2,
                                            adbPath: { nil }, commands: FakeADBRunner(deviceList: ""))
        XCTAssertThrowsError(try missingADB.prepare(preferredSerial: nil)) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription,
                           "ADB was not found. Install Android platform tools, then reconnect.")
        }

        let noDevices = makeSetup(runner: FakeADBRunner(deviceList: "List of devices attached\n"))
        XCTAssertThrowsError(try noDevices.prepare(preferredSerial: nil)) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription,
                           "No USB phone found. Connect a physical phone and enable USB debugging.")
        }
    }

    func testPrepareSurfacesForwardFailureWithoutClaimingOwnership() {
        let runner = FakeADBRunner(deviceList: deviceList, failedOperations: ["forward"])
        let setup = makeSetup(runner: runner)

        XCTAssertThrowsError(try setup.prepare(preferredSerial: nil)) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription, "USB forwarding failed: command rejected")
        }
        XCTAssertFalse(runner.calls.contains { $0.contains("--remove") })
    }

    func testCommandRunnerCapturesOutputAndReportsNonzeroExit() throws {
        let runner = ADBCommandRunner()
        let deadline = ProcessInfo.processInfo.systemUptime + 5

        XCTAssertEqual(try runner.run("/usr/bin/printf", ["%s", "adb output"], deadline: deadline), "adb output")
        XCTAssertThrowsError(try runner.run("/usr/bin/false", [], deadline: deadline)) {
            XCTAssertEqual(($0 as? USBSetupError)?.errorDescription, "ADB exited with status 1.")
        }
    }

    func testCommandRunnerHonorsTimeoutAndCancellation() {
        let timed = ADBCommandRunner()
        XCTAssertThrowsError(try timed.run(
            "/bin/sleep", ["1"], deadline: ProcessInfo.processInfo.systemUptime + 0.05)) {
                XCTAssertEqual(($0 as? USBSetupError)?.errorDescription,
                               "USB connection timed out after 5 seconds. Check the phone and try again.")
            }

        let cancelled = ADBCommandRunner()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.run(
            "/usr/bin/printf", ["%s", "should not run"],
            deadline: ProcessInfo.processInfo.systemUptime + 5)) {
                XCTAssertEqual(($0 as? USBSetupError)?.errorDescription, "USB connection cancelled.")
            }
    }

    private func makeSetup(runner: FakeADBRunner) -> USBConnectionSetup {
        USBConnectionSetup(deadline: ProcessInfo.processInfo.systemUptime + 5,
                           adbPath: { "/fake/adb" }, commands: runner)
    }
}

private final class FakeADBRunner: ADBCommandExecuting, @unchecked Sendable {
    let deviceList: String
    let failedOperations: Set<String>
    private(set) var calls: [[String]] = []

    init(deviceList: String, failedOperations: Set<String> = []) {
        self.deviceList = deviceList
        self.failedOperations = failedOperations
    }

    func cancel() {}

    func run(_ path: String, _ arguments: [String], deadline: TimeInterval) throws -> String {
        calls.append(arguments)
        if arguments.contains("devices") { return deviceList }
        if let operation = failedOperations.first(where: arguments.contains) {
            throw USBSetupError.commandFailed("command rejected")
        }
        return ""
    }
}

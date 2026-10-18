import XCTest
@testable import AndroidWebcamAppRuntime

final class DeviceDiscoveryTests: XCTestCase {
    func testAndroidInventoryKeepsPhysicalUsbPhonesAndTheirAdbState() {
        let output = """
        List of devices attached
        USB123 device usb:1 product:phone model:Galaxy_S23
        USB456 unauthorized usb:2 product:phone model:Pixel_8
        emulator-5554 device
        phone._adb-tls-connect._tcp device
        """

        let devices = DeviceDiscovery.androidDevices(from: output)

        XCTAssertEqual(devices, [
            AndroidDevice(id: "USB123", model: "Galaxy S23", state: "device"),
            AndroidDevice(id: "USB456", model: "Pixel 8", state: "unauthorized"),
        ])
    }

    func testAndroidInventoryHandlesEmptyOrMalformedOutput() {
        XCTAssertTrue(DeviceDiscovery.androidDevices(from: "List of devices attached\n").isEmpty)
        XCTAssertTrue(DeviceDiscovery.androidDevices(from: "not adb output").isEmpty)
    }

    func testAdbCommandsCoverMissingExecutableSuccessAndFailurePaths() {
        XCTAssertTrue(DeviceDiscovery.listAndroidDevices(executable: nil, command: { _, _ in
            XCTFail("A command must not run without an adb executable")
            return nil
        }).isEmpty)
        XCTAssertFalse(DeviceDiscovery.forwardPort(1234, executable: nil, command: { _, _ in nil }))
        XCTAssertFalse(DeviceDiscovery.configureDefaultUsbMode(serial: "phone", executable: nil,
                                                                 command: { _, _ in "ok" }))

        var calls: [(String, [String])] = []
        let runner: (String, [String]) -> String? = { path, arguments in
            calls.append((path, arguments))
            return arguments.first == "devices" ? "List of devices attached\nserial device usb:1 model:Pixel_9\n" : "ok"
        }
        let devices = DeviceDiscovery.listAndroidDevices(executable: "/fake/adb", command: runner)
        XCTAssertEqual(devices.map(\.model), ["Pixel 9"])
        XCTAssertTrue(DeviceDiscovery.forwardPort(1234, executable: "/fake/adb", command: runner))
        XCTAssertTrue(DeviceDiscovery.configureDefaultUsbMode(serial: "serial", executable: "/fake/adb",
                                                                command: runner))
        DeviceDiscovery.removeForward(1234, executable: "/fake/adb", command: runner)

        XCTAssertEqual(calls.map(\.0), Array(repeating: "/fake/adb", count: 5))
        XCTAssertEqual(calls[0].1, ["devices", "-l"])
        XCTAssertEqual(calls[1].1, ["forward", "tcp:1234", "tcp:1234"])
        XCTAssertEqual(calls[2].1, ["-s", "serial", "shell", "svc", "usb", "setScreenUnlockedFunctions", "mtp"])
        XCTAssertEqual(calls[3].1, ["-s", "serial", "shell", "svc", "usb", "setFunctions", "mtp"])
        XCTAssertEqual(calls[4].1, ["forward", "--remove", "tcp:1234"])

        var invocation = 0
        XCTAssertFalse(DeviceDiscovery.configureDefaultUsbMode(executable: "/fake/adb", command: { _, _ in
            invocation += 1
            return invocation == 1 ? "ok" : nil
        }))
    }
}

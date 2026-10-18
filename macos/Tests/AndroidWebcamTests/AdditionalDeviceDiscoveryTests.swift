import XCTest
@testable import AndroidWebcamAppRuntime

final class AdditionalDeviceDiscoveryTests: XCTestCase {
    func testSystemCommandRunnerReturnsEmptyInventoryForNonAdbOutputAndMissingExecutable() {
        XCTAssertTrue(DeviceDiscovery.listAndroidDevices(executable: "/bin/echo").isEmpty)
        XCTAssertTrue(DeviceDiscovery.listAndroidDevices(executable: "/wamc/nonexistent-adb").isEmpty)
        XCTAssertTrue(DeviceDiscovery.forwardPort(executable: "/bin/echo"))
        DeviceDiscovery.removeForward(executable: "/bin/echo")
        XCTAssertTrue(DeviceDiscovery.configureDefaultUsbMode(executable: "/bin/echo"))
        DeviceDiscovery.removeForward(executable: nil)
    }

    func testNativeWebcamInventoryContainsOnlyNamedDevices() {
        XCTAssertTrue(DeviceDiscovery.nativeUVCWebcams().allSatisfy { !$0.isEmpty })
    }
}

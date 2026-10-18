import Foundation
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class USBControllerCoverageTests: XCTestCase {
    func testUSBPreparationStartsTransportAndInventoryRemovalDisconnectsAndCleansForward() async throws {
        let prepared = USBConnectionSetup.PreparedConnection(serial: "usb-phone", port: 12345,
                                                              warnings: ["Mode unchanged"])
        let setup = StubUSBPreparation(result: .success(prepared))
        let removals = ForwardRemovalRecorder()
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport, makeUSBSetup: { _ in setup },
                                               removeForward: removals.record)
        let preferences = isolatedDefaults()
        preferences.set(false, forKey: "wamc.startStreamingAutomatically")
        let model = AppModel(preferences: preferences, startServices: false, connection: controller,
                             deviceInventory: EmptyUSBInventory())
        controller.connect(to: .usb(serial: "usb-phone"), manual: true)
        try await waitUntil("USB preparation starts the transport") { transport.attempt != nil }
        XCTAssertTrue(model.statusText.contains("Mode unchanged"))
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "USB phone"]), attempt: attempt)
        try await waitUntil("USB phone connects") { model.connected }
        XCTAssertEqual(model.transportLabel, "USB")
        XCTAssertTrue(model.isSourceActive(.usb(serial: nil)))
        model.devices = [AndroidDevice(id: "usb-phone", model: "USB phone", state: "device")]
        XCTAssertTrue(model.sessionAction.sourceLabel.contains("USB phone"))

        model.refreshDevices()
        try await waitUntil("missing USB inventory disconnects") { !model.connected }
        XCTAssertEqual(removals.entries.map(\.0), ["usb-phone"])
        XCTAssertEqual(removals.entries.map(\.1), [12345])
    }

    func testUSBPreparationFailurePublishesAnActionableFailure() async throws {
        let setup = StubUSBPreparation(result: .failure(USBSetupError.message("Allow USB debugging")))
        let controller = ConnectionController(receiver: FakeStreamTransport(), makeUSBSetup: { _ in setup },
                                               removeForward: { _, _ in XCTFail("No forward was created") })
        controller.connect(to: .usb(serial: nil), manual: true)
        try await waitUntil("USB setup failure reaches controller") { controller.failureMessage != nil }
        XCTAssertEqual(controller.failureMessage, "Allow USB debugging")
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testStaleSuccessfulPreparationCleansOnlyItsOwnForward() async throws {
        let started = expectation(description: "USB preparation started")
        let prepared = USBConnectionSetup.PreparedConnection(serial: "stale-phone", port: 23456, warnings: [])
        let setup = StubUSBPreparation(result: .success(prepared), waitForRelease: true,
                                       onPrepare: { started.fulfill() })
        let removals = ForwardRemovalRecorder()
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport, makeUSBSetup: { _ in setup },
                                               removeForward: removals.record)
        controller.connect(to: .usb(serial: nil), manual: true)
        await fulfillment(of: [started], timeout: 1)
        controller.connect(to: .address("127.0.0.1", 27183), manual: true)
        setup.release()
        try await waitUntil("stale preparation removes its reserved forward") { !removals.entries.isEmpty }
        XCTAssertEqual(controller.state, .connecting(.address("127.0.0.1", 27183)))
        XCTAssertEqual(removals.entries.map(\.0), ["stale-phone"])
        controller.disconnect()
    }
}

private final class StubUSBPreparation: USBConnectionPreparing, @unchecked Sendable {
    private let result: Result<USBConnectionSetup.PreparedConnection, Error>
    private let condition = NSCondition()
    private var released: Bool
    private let onPrepare: @Sendable () -> Void
    init(result: Result<USBConnectionSetup.PreparedConnection, Error>, waitForRelease: Bool = false,
         onPrepare: @escaping @Sendable () -> Void = {}) {
        self.result = result
        released = !waitForRelease
        self.onPrepare = onPrepare
    }
    func cancel() {}
    func prepare(preferredSerial: String?) throws -> USBConnectionSetup.PreparedConnection {
        onPrepare()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
        return try result.get()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ForwardRemovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, UInt16)] = []
    var entries: [(String, UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
    func record(_ serial: String, _ port: UInt16) {
        lock.lock()
        values.append((serial, port))
        lock.unlock()
    }
}

private struct EmptyUSBInventory: DeviceInventory {
    func listAndroidDevices() -> [AndroidDevice] { [] }
    func nativeUVCWebcams() -> [String] { [] }
    func configureDefaultUsbMode(serial: String?) -> Bool { true }
}

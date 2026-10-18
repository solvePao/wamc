import Foundation
import Network
import XCTest
import AndroidWebcamCore
@testable import AndroidWebcamAppRuntime

@MainActor
final class SessionModelTests: XCTestCase {
    func testUntrustedSourceRequiresConfirmationBeforeSwitchingActiveSession() throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = SessionModel(connection: connection)
        let phone = DiscoveredDevice(id: "phone-id", instanceName: "Phone", model: "Phone",
                                     brand: "", sdk: nil, port: 27183, version: 2)
        let wifi = ConnectionTarget.wifi(phone)
        let address = ConnectionTarget.address("127.0.0.1", 27183)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 27183)!)
        var trustedIDs: [String] = []
        var cameraStarts = 0
        model.endpointForDevice = { _ in endpoint }
        model.isTrusted = { _ in false }
        model.trustDevice = { trustedIDs.append($0.id) }
        model.onStartCamera = { cameraStarts += 1 }

        model.select(address)
        model.start()
        XCTAssertEqual(connection.state, .connecting(address))
        XCTAssertTrue(model.wantsStreaming)

        model.select(wifi)
        XCTAssertEqual(model.trustRequest, phone)
        XCTAssertEqual(model.selectedSource, address)

        model.confirmTrust(try XCTUnwrap(model.trustRequest))
        XCTAssertNil(model.trustRequest)
        XCTAssertEqual(model.selectedSource, wifi)
        XCTAssertEqual(connection.state, .connecting(wifi))
        XCTAssertEqual(trustedIDs, [phone.id])
        XCTAssertTrue(model.switching)

        model.connectionReady()
        XCTAssertFalse(model.switching)
        XCTAssertEqual(cameraStarts, 1)
        model.stop()
        XCTAssertFalse(model.wantsStreaming)
        XCTAssertNil(model.trustRequest)
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testDiscoveryRespectsManualSourceAndAutomaticStartPreference() {
        let connection = ConnectionController(receiver: FakeStreamTransport())
        let model = SessionModel(connection: connection)
        model.startsAutomatically = false
        let cable = AndroidDevice(id: "usb-1", model: "Android", state: "device")
        let phone = DiscoveredDevice(id: "wifi-1", instanceName: "Phone", model: "Phone",
                                     brand: "", sdk: nil, port: 27183, version: 2)
        model.isTrusted = { _ in true }

        model.discovered(usb: [cable], wifi: [phone])
        XCTAssertEqual(model.selectedSource, .usb(serial: nil))
        XCTAssertEqual(connection.state, .disconnected)

        let manualAddress = ConnectionTarget.address("192.168.1.5", 27183)
        model.select(manualAddress)
        model.discovered(usb: [cable], wifi: [phone])
        XCTAssertEqual(model.selectedSource, manualAddress)
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testSessionSnapshotDescribesConnectedStreamStates() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = SessionModel(connection: connection)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        let connected = expectation(description: "connection reaches connected state")
        connection.onStateChange = { state, _ in
            if state.isConnected { connected.fulfill() }
        }
        model.select(target)
        connection.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        await fulfillment(of: [connected], timeout: 1)

        let idle = model.snapshot(feed: .idle, sourceLabel: "Phone")
        XCTAssertEqual(idle.action, .start)
        let starting = model.snapshot(feed: .starting, sourceLabel: "Phone")
        XCTAssertEqual(starting.action, .stop)
        XCTAssertTrue(starting.isProgress)
        XCTAssertEqual(model.snapshot(feed: .updating, sourceLabel: "Phone").status, "Applying quality…")
        XCTAssertEqual(model.snapshot(feed: .stalled, sourceLabel: "Phone").symbol, "stop.fill")
        XCTAssertTrue(model.snapshot(feed: .live, sourceLabel: "Phone").status.contains("Wi-Fi"))

        model.connectionChanged(.disconnected)
        XCTAssertFalse(model.wantsStreaming)
    }
}

extension SessionModelTests {
    func testAutomaticPreferenceMigratesLegacyFlagsAndPersistsChanges() {
        let keys = ["wamc.startStreamingAutomatically", "wamc.autoConnect", "wamc.autoStart"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.removeObject(forKey: keys[0])
        UserDefaults.standard.set(true, forKey: keys[1])
        UserDefaults.standard.set(false, forKey: keys[2])
        let model = SessionModel(connection: ConnectionController(receiver: FakeStreamTransport()))
        XCTAssertFalse(model.startsAutomatically)
        model.startsAutomatically = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: keys[0]))
        UserDefaults.standard.removeObject(forKey: keys[0])
        UserDefaults.standard.removeObject(forKey: keys[1])
        UserDefaults.standard.removeObject(forKey: keys[2])
        XCTAssertTrue(SessionModel(connection: ConnectionController(receiver: FakeStreamTransport())).startsAutomatically)
    }

    func testDiscoverySelectsTrustedWifiAndStartsOnlyWhenEndpointAvailable() {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = SessionModel(connection: connection)
        let phone = DiscoveredDevice(id: "automatic-phone", instanceName: "Phone", model: "Pixel",
                                     brand: "Google", sdk: 35, port: 27183, version: 2)
        model.startsAutomatically = true
        model.isTrusted = { $0.id == phone.id }
        model.endpointForDevice = { _ in .hostPort(host: "127.0.0.1", port: 27183) }
        model.discovered(usb: [], wifi: [phone])
        XCTAssertEqual(model.selectedSource, .wifi(phone))
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertEqual(connection.state, .connecting(.wifi(phone)))
        XCTAssertEqual(model.snapshot(feed: .starting, sourceLabel: "Pixel").action, .cancel)
        model.stop()
        model.discovered(usb: [], wifi: [phone])
        XCTAssertFalse(model.wantsStreaming, "Explicit Stop suppresses automatic discovery restart")
    }

    func testMissingWifiEndpointFailsSynchronouslyAndTrustCanBeCancelled() {
        let connection = ConnectionController(receiver: FakeStreamTransport())
        let model = SessionModel(connection: connection)
        let phone = DiscoveredDevice(id: "no-endpoint", instanceName: "Phone", model: "Phone",
                                     brand: "", sdk: nil, port: 27183, version: 2)
        var trusted = false
        model.isTrusted = { _ in trusted }
        model.trustDevice = { _ in trusted = true }
        model.select(.wifi(phone))
        XCTAssertEqual(model.snapshot(feed: .idle, sourceLabel: "Phone").title, "Trust & Start")
        model.start()
        XCTAssertTrue(trusted)
        XCTAssertFalse(model.wantsStreaming)
        XCTAssertEqual(model.snapshot(feed: .idle, sourceLabel: "Phone").title, "Retry stream")
        model.cancelTrust()
        XCTAssertNil(model.trustRequest)
        XCTAssertFalse(model.matchesSelection(nil))
        XCTAssertTrue(model.isSelected(.wifi(phone)))
        model.select(.usb(serial: "serial"))
        XCTAssertTrue(model.isSelected(.usb(serial: nil)))
        model.connectionReady()
        XCTAssertFalse(model.wantsStreaming)
    }

    func testStartOnExistingConnectionReusesTransportAndStartsCamera() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = SessionModel(connection: connection)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        let connected = expectation(description: "connected")
        connection.onStateChange = { state, _ in if state.isConnected { connected.fulfill() } }
        model.select(target)
        connection.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        await fulfillment(of: [connected], timeout: 1)
        var starts = 0
        model.onStartCamera = { starts += 1 }
        model.start()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(transport.attempt, attempt)
        model.select(target)
        XCTAssertNil(model.trustRequest)
        XCTAssertTrue(model.matchesSelection(target))
        model.stop()
    }
}

extension SessionModelTests {
    func testStopCancelsDeferredSourceSwitchAndIgnoresStartDuringTeardown() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = SessionModel(connection: connection)
        let original = ConnectionTarget.address("127.0.0.1", 27183)
        model.select(original)
        model.start()
        let connected = expectation(description: "initial session connected")
        connection.onStateChange = { state, _ in if state.isConnected { connected.fulfill() } }
        transport.emit(.hello(["model": "Phone"]), attempt: try XCTUnwrap(transport.attempt))
        await fulfillment(of: [connected], timeout: 1)
        transport.completesControls = false
        model.select(.address("127.0.0.2", 27183))
        XCTAssertTrue(model.switching)
        XCTAssertEqual(model.snapshot(feed: .live, sourceLabel: "Other phone").action, .cancel)
        model.start()
        XCTAssertTrue(model.switching, "Start during teardown must not create another attempt")
        model.stop()
        let stopping = model.snapshot(feed: .live, sourceLabel: "Phone")
        XCTAssertEqual(stopping.action, .none)
        XCTAssertFalse(stopping.enabled)
        let disconnected = expectation(description: "teardown completes")
        connection.onStateChange = { state, _ in if state == .disconnected { disconnected.fulfill() } }
        for completion in transport.pendingCompletions { completion() }
        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertNil(transport.attempt, "Cancelled source switch must not reconnect after teardown")
        XCTAssertFalse(model.wantsStreaming)
        XCTAssertFalse(model.switching)
    }
}

import Foundation
import Network
import XCTest
import AndroidWebcamCore
@testable import AndroidWebcamAppRuntime

final class WifiDiscoveryTests: XCTestCase {
    func testAdvertisementSnapshotFiltersInvalidAndEmulatorAndKeepsNewestIdentity() {
        let discovery = WifiDiscovery()
        var updates: [[DiscoveredDevice]] = []
        discovery.onDevicesChanged = { updates.append($0) }
        let firstEndpoint = service("First")
        let newestEndpoint = service("Newest")
        let otherEndpoint = service("Other")

        discovery.apply([
            .init(instanceName: "first", txt: record(id: "phone-1", model: "Old"), endpoint: firstEndpoint),
            .init(instanceName: "emulator", txt: record(id: "emu-1", model: "sdk_gphone64_arm64"), endpoint: service("Emulator")),
            .init(instanceName: "invalid", txt: record(id: "bad id", model: "Invalid"), endpoint: service("Invalid")),
            .init(instanceName: "new", txt: record(id: "phone-1", model: "Galaxy"), endpoint: newestEndpoint),
            .init(instanceName: "other", txt: record(id: "phone-2", model: "Pixel"), endpoint: otherEndpoint),
        ])

        XCTAssertEqual(discovery.devices.map(\.id), ["phone-1", "phone-2"])
        XCTAssertEqual(discovery.devices.first?.model, "Galaxy")
        XCTAssertEqual(discovery.endpoint(forId: "phone-1"), newestEndpoint)
        XCTAssertEqual(discovery.endpoint(forId: "emu-1"), nil)
        XCTAssertEqual(discovery.statusText, "Found 2 phone(s) on Wi-Fi")
        XCTAssertEqual(updates.count, 1)
    }

    func testEmptyAdvertisementSnapshotClearsDevicesEndpointsAndStatus() {
        let discovery = WifiDiscovery()
        discovery.apply([.init(instanceName: "phone", txt: record(id: "phone-1", model: "Phone"),
                               endpoint: service("Phone"))])

        discovery.apply([])

        XCTAssertTrue(discovery.devices.isEmpty)
        XCTAssertNil(discovery.endpoint(forId: "phone-1"))
        XCTAssertEqual(discovery.statusText, "No phones found on this Wi-Fi network yet")
    }

    func testBrowserStatusCoversReadyWaitFailureAndStoppedStates() {
        let discovery = WifiDiscovery()
        discovery.applyBrowserStatus(.ready)
        XCTAssertEqual(discovery.statusText, "No phones found on this Wi-Fi network yet")
        discovery.applyBrowserStatus(.waiting("network unavailable"))
        XCTAssertEqual(discovery.statusText, "Wi-Fi discovery waiting: network unavailable")
        discovery.applyBrowserStatus(.failed("permission denied"))
        XCTAssertEqual(discovery.statusText, "Wi-Fi discovery failed: permission denied")
        discovery.applyBrowserStatus(.other)
        XCTAssertEqual(discovery.statusText, "Wi-Fi discovery failed: permission denied")

        discovery.apply([.init(instanceName: "phone", txt: record(id: "phone-1", model: "Phone"),
                               endpoint: service("Phone"))])
        discovery.applyBrowserStatus(.ready)
        XCTAssertEqual(discovery.statusText, "Found 1 phone(s) on Wi-Fi")
        discovery.stop()
        XCTAssertTrue(discovery.devices.isEmpty)
        XCTAssertEqual(discovery.statusText, "Wi-Fi discovery off")
    }

    @MainActor
    func testTrustedDeviceStoreLoadsPersistsAndForgetsIdentities() {
        let defaults = UserDefaults.standard
        let key = "wamc.trustedDeviceIds"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(["known-phone"], forKey: key)
        let store = TrustedDeviceStore()

        XCTAssertTrue(store.isTrusted("known-phone"))
        XCTAssertFalse(store.isTrusted("new-phone"))
        store.trust("new-phone")
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: key)?.contains("new-phone") == true)
        store.untrust("known-phone")
        XCTAssertFalse(store.isTrusted("known-phone"))
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: key)?.contains("new-phone") == true)
    }

    @MainActor
    func testBrowserLifecycleIgnoresCallbacksFromReplacedBrowser() async throws {
        var browsers: [NWBrowser] = []
        let discovery = WifiDiscovery(startBrowser: { browser, _ in browsers.append(browser) })
        discovery.start()
        discovery.start()
        XCTAssertEqual(browsers.count, 1, "Repeated start must retain one browser")
        let original = try XCTUnwrap(browsers.first)
        original.stateUpdateHandler?(.ready)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.statusText, "No phones found on this Wi-Fi network yet")
        original.stateUpdateHandler?(.waiting(.posix(.ENETDOWN)))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(discovery.statusText.hasPrefix("Wi-Fi discovery waiting:"))
        original.stateUpdateHandler?(.failed(.posix(.EACCES)))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(discovery.statusText.hasPrefix("Wi-Fi discovery failed:"))
        original.stateUpdateHandler?(.setup)
        original.browseResultsChangedHandler?([], [])
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.statusText, "No phones found on this Wi-Fi network yet")

        discovery.stop()
        discovery.start()
        XCTAssertEqual(browsers.count, 2)
        original.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        original.browseResultsChangedHandler?([], [])
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.statusText, "Searching for phones on Wi-Fi…",
                       "Late callbacks must not overwrite the new search")
        discovery.stop()
        XCTAssertEqual(discovery.statusText, "Wi-Fi discovery off")
    }

    private func record(id: String, model: String) -> [String: String] {
        ["id": id, "model": model, "brand": "Test", "v": "2", "port": "27183"]
    }

    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_wamc._tcp", domain: "local", interface: nil)
    }
}

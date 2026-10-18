import Foundation
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class PreferenceIsolationTests: XCTestCase {
    func testSessionPreferenceWritesStayInsideTheirOwningSuite() {
        let first = isolatedDefaults()
        let second = isolatedDefaults()
        let firstSession = SessionModel(preferences: first,
            connection: ConnectionController(receiver: FakeStreamTransport()))
        let secondSession = SessionModel(preferences: second,
            connection: ConnectionController(receiver: FakeStreamTransport()))

        firstSession.startsAutomatically = false

        XCTAssertFalse(first.bool(forKey: "wamc.startStreamingAutomatically"))
        XCTAssertTrue(secondSession.startsAutomatically)
        XCTAssertTrue(second.bool(forKey: "wamc.startStreamingAutomatically"))
        XCTAssertFalse(SessionModel(preferences: first,
            connection: ConnectionController(receiver: FakeStreamTransport())).startsAutomatically)
    }

    func testAppModelPropagatesItsPreferenceSuiteToSessionAndTrustStore() {
        let first = isolatedDefaults()
        let second = isolatedDefaults()
        let firstModel = AppModel(preferences: first, startServices: false)
        let secondModel = AppModel(preferences: second, startServices: false)

        firstModel.session.startsAutomatically = false
        firstModel.trustedStore.trust("first-phone")

        XCTAssertTrue(secondModel.session.startsAutomatically)
        XCTAssertFalse(secondModel.trustedStore.isTrusted("first-phone"))
        XCTAssertTrue(TrustedDeviceStore(preferences: first).isTrusted("first-phone"))
        XCTAssertEqual(first.stringArray(forKey: "wamc.trustedDeviceIds"), ["first-phone"])
    }

    func testFirstRunDecisionRequiresBothCurrentVersionAndInstalledLocation() {
        let defaults = isolatedDefaults()
        let installed = URL(fileURLWithPath: "/Applications/WAMC.app")
        XCTAssertTrue(SetupModel.needsFirstRunSetup(preferences: defaults, bundleURL: installed))

        defaults.set(SetupModel.version, forKey: "wamc.setupVersion")

        XCTAssertFalse(SetupModel.needsFirstRunSetup(preferences: defaults, bundleURL: installed))
        XCTAssertTrue(SetupModel.needsFirstRunSetup(preferences: defaults,
            bundleURL: URL(fileURLWithPath: "/tmp/WAMC.app")))
    }
}

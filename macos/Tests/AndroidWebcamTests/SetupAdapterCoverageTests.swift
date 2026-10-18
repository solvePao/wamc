import AppKit
import AVFoundation
import Security
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class SetupAdapterCoverageTests: XCTestCase {
    func testSystemEnvironmentForwardsPermissionSettingsAndTerminationOperations() {
        var opened: URL?
        var terminated = false
        var granted = false
        let environment = SystemSetupEnvironment(readAuthorization: { type in
            XCTAssertEqual(type, .video)
            return .denied
        }, requestAccess: { type, completion in
            XCTAssertEqual(type, .video)
            completion(true)
        }, readSinkRegistration: { true }, openURL: { opened = $0; return true },
        terminate: { sender in XCTAssertNil(sender); terminated = true })

        XCTAssertEqual(environment.cameraAuthorization(), .denied)
        environment.requestCameraAccess { granted = $0 }
        XCTAssertTrue(granted)
        XCTAssertTrue(environment.sinkIsRegistered())
        environment.openPrivacyPane("Privacy_Camera")
        XCTAssertEqual(opened?.scheme, "x-apple.systempreferences")
        XCTAssertTrue(opened?.absoluteString.contains("Privacy_Camera") == true)
        environment.terminateApplication()
        XCTAssertTrue(terminated)
    }

    func testSigningValidationAcceptsMatchingHostAndExtensionAndRejectsMismatches() throws {
        let host = Bundle(for: SetupAdapterCoverageTests.self)
        let team = "TESTTEAM"
        let identifier = CameraExtensionManager.extensionBundleID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Camera.systemextension/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Camera",
            "CFBundlePackageType": "SYSX", "CFBundleVersion": "1",
            "CMIOExtension": ["CMIOExtensionMachServiceName": "\(team).\(identifier)"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let extensionBundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let hostInfo: [String: Any] = [kSecCodeInfoTeamIdentifier as String: team,
            kSecCodeInfoEntitlementsDict as String: ["com.apple.developer.system-extension.install": true]]
        let extensionInfo: [String: Any] = [kSecCodeInfoTeamIdentifier as String: team,
            kSecCodeInfoEntitlementsDict as String: ["com.apple.security.app-sandbox": true,
                "com.apple.security.application-groups": ["\(team).com.androidwebcam.app"]]]
        let information: (URL) -> [String: Any]? = { $0 == host.bundleURL ? hostInfo : extensionInfo }

        XCTAssertNil(SetupModel.signingIssue(in: host, information: information,
                                             extensionBundle: { _ in extensionBundle }))
        XCTAssertNotNil(SetupModel.signingIssue(in: host, information: { _ in nil }))
        XCTAssertNotNil(SetupModel.signingIssue(in: host, information: { url in
            url == host.bundleURL ? hostInfo : [kSecCodeInfoTeamIdentifier as String: "OTHERTEAM"]
        }, extensionBundle: { _ in extensionBundle }))
        XCTAssertNotNil(SetupModel.signingIssue(in: host, information: information,
                                             extensionBundle: { _ in nil }))
        XCTAssertNotNil(SetupModel.signingIssue(in: host, information: information,
                                             extensionBundle: { _ in host }))
    }

    func testFoundationFileManagerRemovesAnExistingItem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("temporary bundle".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FoundationApplicationBundleFileManager().removeItem(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

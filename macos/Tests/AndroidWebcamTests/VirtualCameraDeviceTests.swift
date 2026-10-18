import XCTest
import CoreMediaIO
@testable import AndroidWebcamAppRuntime

final class VirtualCameraDeviceTests: XCTestCase {
    func testSinkMustMatchWamcDeviceUIDAndStreamName() {
        XCTAssertTrue(VirtualCameraDevice.sinkIsRegistered(using: FakeCameraDeviceQuery(devices: [
            CameraDeviceSnapshot(uid: VirtualCameraDevice.uid,
                                 streamNames: [VirtualCameraDevice.sinkName]),
        ])))

        XCTAssertFalse(VirtualCameraDevice.sinkIsRegistered(using: FakeCameraDeviceQuery(devices: [
            CameraDeviceSnapshot(uid: "unrelated-device", streamNames: [VirtualCameraDevice.sinkName]),
            CameraDeviceSnapshot(uid: VirtualCameraDevice.uid, streamNames: ["OBS Virtual Camera"]),
        ])))
    }

    func testCoreMediaIoQueryFailureFailsClosed() {
        XCTAssertFalse(VirtualCameraDevice.sinkIsRegistered(using: FakeCameraDeviceQuery(error: .unavailable)))
    }

    func testCoreMediaIoQueryBuildsSnapshotsAndSkipsMissingProperties() throws {
        let reader = FakeCoreMediaIOPropertyReader(
            objectIDs: [UInt32(kCMIOObjectSystemObject): [10, 20], 10: [11, 12], 20: [21]],
            strings: [10: "wamc-device", 11: VirtualCameraDevice.sinkName, 21: "unrelated stream"])

        XCTAssertEqual(try CoreMediaIODeviceQuery(reader: reader).devices(), [
            CameraDeviceSnapshot(uid: "wamc-device", streamNames: [VirtualCameraDevice.sinkName]),
        ])
    }

    func testCoreMediaIoQueryPropagatesPropertyReadFailure() {
        XCTAssertThrowsError(try CoreMediaIODeviceQuery(
            reader: FakeCoreMediaIOPropertyReader(failure: .unavailable)).devices())
    }
}

private struct FakeCameraDeviceQuery: CameraDeviceQuery {
    enum Failure: LocalizedError { case unavailable }
    let snapshots: [CameraDeviceSnapshot]
    let error: Failure?

    init(devices: [CameraDeviceSnapshot]) {
        snapshots = devices
        error = nil
    }

    init(error: Failure) {
        snapshots = []
        self.error = error
    }

    func devices() throws -> [CameraDeviceSnapshot] {
        if let error { throw error }
        return snapshots
    }
}

private struct FakeCoreMediaIOPropertyReader: CoreMediaIOPropertyReading {
    enum Failure: Error { case unavailable }
    let objectIDs: [UInt32: [UInt32]]
    let strings: [UInt32: String]
    let failure: Failure?

    init(objectIDs: [UInt32: [UInt32]] = [:], strings: [UInt32: String] = [:], failure: Failure? = nil) {
        self.objectIDs = objectIDs
        self.strings = strings
        self.failure = failure
    }

    func objects(for object: UInt32, selector: UInt32) throws -> [UInt32] {
        if let failure { throw failure }
        return objectIDs[object] ?? []
    }

    func string(for object: UInt32, selector: UInt32) throws -> String? {
        if let failure { throw failure }
        return strings[object]
    }
}

extension VirtualCameraDeviceTests {
    func testSystemDeviceInspectionHasConsistentRegistrationResult() throws {
        // Exercise the real read-only CoreMediaIO adapter against the CI Mac.
        // Its hardware inventory may legitimately be empty.
        let snapshots = try CoreMediaIODeviceQuery().devices()
        let expected = snapshots.contains {
            $0.uid == VirtualCameraDevice.uid && $0.streamNames.contains(VirtualCameraDevice.sinkName)
        }
        XCTAssertEqual(VirtualCameraDevice.sinkIsRegistered(), expected)
        XCTAssertTrue(snapshots.allSatisfy { !$0.uid.isEmpty })
    }

    func testEmptyStreamInventoryNeverRegistersSink() throws {
        let reader = FakeCoreMediaIOPropertyReader(
            objectIDs: [UInt32(kCMIOObjectSystemObject): [10]],
            strings: [10: VirtualCameraDevice.uid])
        let snapshots = try CoreMediaIODeviceQuery(reader: reader).devices()
        XCTAssertEqual(snapshots, [CameraDeviceSnapshot(uid: VirtualCameraDevice.uid, streamNames: [])])
        XCTAssertFalse(VirtualCameraDevice.sinkIsRegistered(using: FakeCameraDeviceQuery(devices: snapshots)))
    }
}

extension VirtualCameraDeviceTests {
    func testNativePropertyReaderDecodesIdsAndRetainedStringsWithoutHardware() throws {
        var access = CoreMediaIOPropertyAccess()
        access.dataSize = { _, address, _, _, size in
            XCTAssertEqual(address?.pointee.mScope, UInt32(kCMIOObjectPropertyScopeGlobal))
            size?.pointee = 8
            return noErr
        }
        access.data = { _, address, _, _, _, used, output in
            if address?.pointee.mSelector == UInt32(kCMIODevicePropertyDeviceUID) {
                output?.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee =
                    Unmanaged.passRetained("test-camera" as CFString)
                used?.pointee = UInt32(MemoryLayout<CFString>.size)
            } else {
                let ids = output?.assumingMemoryBound(to: UInt32.self)
                ids?[0] = 10
                ids?[1] = 20
                used?.pointee = 8
            }
            return noErr
        }
        let reader = CoreMediaIOSystemPropertyReader(access: access)
        XCTAssertEqual(try reader.objects(for: 1, selector: UInt32(kCMIOHardwarePropertyDevices)), [10, 20])
        XCTAssertEqual(try reader.string(for: 10, selector: UInt32(kCMIODevicePropertyDeviceUID)), "test-camera")
    }

    func testNativePropertyReaderHandlesEmptyMalformedAndFailedProperties() throws {
        var access = CoreMediaIOPropertyAccess()
        for size: UInt32 in [0, 1] {
            access.dataSize = { _, _, _, _, output in output?.pointee = size; return noErr }
            XCTAssertEqual(try CoreMediaIOSystemPropertyReader(access: access).objects(for: 1, selector: 1), [])
        }
        access.dataSize = { _, _, _, _, _ in -1 }
        XCTAssertThrowsError(try CoreMediaIOSystemPropertyReader(access: access).objects(for: 1, selector: 1)) {
            XCTAssertTrue($0.localizedDescription.contains("OSStatus -1"))
        }
        access.dataSize = { _, _, _, _, output in output?.pointee = 4; return noErr }
        access.data = { _, _, _, _, _, _, _ in -2 }
        let failed = CoreMediaIOSystemPropertyReader(access: access)
        XCTAssertThrowsError(try failed.objects(for: 1, selector: 1))
        XCTAssertThrowsError(try failed.string(for: 1, selector: 1))
        access.data = { _, _, _, _, _, _, _ in noErr }
        XCTAssertNil(try CoreMediaIOSystemPropertyReader(access: access).string(for: 1, selector: 1))
    }
}

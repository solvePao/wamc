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

import XCTest
import AndroidWebcamCore

final class CameraHealthSnapshotTests: XCTestCase {
    func testFreshnessRequiresSequenceAndNonFutureTimestampWithinOneSecond() {
        let snapshot = CameraHealthSnapshot(instanceID: "extension", sinkSequence: 1, sinkReceivedAt: 10,
                                            sourceSequence: 2, sourcePublishedAt: 10)
        for now in [10.0, 10.999] {
            XCTAssertTrue(snapshot.hasFreshSink(at: now))
            XCTAssertTrue(snapshot.hasFreshSource(at: now))
        }
        for now in [9.999, 11.0, 100.0] {
            XCTAssertFalse(snapshot.hasFreshSink(at: now))
            XCTAssertFalse(snapshot.hasFreshSource(at: now))
        }
        let inactive = CameraHealthSnapshot(instanceID: "extension", sinkSequence: 0, sinkReceivedAt: 10,
                                            sourceSequence: 0, sourcePublishedAt: 10)
        XCTAssertFalse(inactive.hasFreshSink(at: 10))
        XCTAssertFalse(inactive.hasFreshSource(at: 10))
    }

    func testSnapshotJsonPreservesCrossProcessContract() throws {
        let original = CameraHealthSnapshot(instanceID: "extension", sinkSequence: 42, sinkReceivedAt: 10,
                                            sourceSequence: 43, sourcePublishedAt: 11)
        let decoded = try JSONDecoder().decode(CameraHealthSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.contractVersion, CameraHealthSnapshot.version)
        XCTAssertEqual(decoded.instanceID, "extension")
        XCTAssertEqual(decoded.sinkSequence, 42)
        XCTAssertEqual(decoded.sinkReceivedAt, 10)
        XCTAssertEqual(decoded.sourceSequence, 43)
        XCTAssertEqual(decoded.sourcePublishedAt, 11)
    }
}

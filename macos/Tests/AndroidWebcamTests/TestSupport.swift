import Foundation
import XCTest

extension XCTestCase {
    /// Every fixture owns a persistent domain, including across worker processes.
    func isolatedDefaults() -> UserDefaults {
        let name = "WAMCTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

extension XCTestCase {
    /// Wait for already-enqueued main-queue callbacks without a wall-clock delay.
    @MainActor
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval = 1,
                   file: StaticString = #filePath, line: UInt = #line,
                   condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail(description, file: file, line: line)
                throw NSError(domain: "WAMCTests.waitUntil", code: 1)
            }
            await Task.yield()
        }
    }
}

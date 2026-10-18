import SwiftUI
import AndroidWebcamAppRuntime

#if !WAMC_COVERAGE_TESTING
@main
#endif
struct WAMCRunner: App {
    private let startServices: Bool

    init() { self.init(startServices: true) }
    init(startServices: Bool) { self.startServices = startServices }

    var body: some Scene {
        WAMCEntry(startServices: startServices).body
    }
}

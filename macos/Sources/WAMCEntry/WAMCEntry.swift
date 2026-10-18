import SwiftUI
import AndroidWebcamAppRuntime

@main
struct WAMCEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WAMCApplication()
    }
}

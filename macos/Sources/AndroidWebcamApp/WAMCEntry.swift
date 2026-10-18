import SwiftUI

public struct WAMCEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let startServices: Bool

    public init() { self.init(startServices: true) }

    public init(startServices: Bool) { self.startServices = startServices }

    public var body: some Scene {
        WAMCApplication(startServices: startServices)
    }
}

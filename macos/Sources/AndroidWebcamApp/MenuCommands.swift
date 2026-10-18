import AppKit
import SwiftUI

@MainActor
protocol MenuWindowOpening {
    func callAsFunction(id: String)
}

extension OpenWindowAction: MenuWindowOpening {}

@MainActor
protocol MenuApplicationDriving {
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps flag: Bool)
    func terminate(_ sender: Any?)
}

extension NSApplication: MenuApplicationDriving {}

/// Keeps native application actions separate from menu rendering.
@MainActor
struct MenuCommands {
    let model: AppModel
    let windows: any MenuWindowOpening
    var application: any MenuApplicationDriving = NSApplication.shared

    func showWindow() {
        windows(id: "main")
        _ = application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
    }

    func showSetup() {
        model.setup.showSetup = true
        showWindow()
    }

    func quit() { application.terminate(nil) }
}

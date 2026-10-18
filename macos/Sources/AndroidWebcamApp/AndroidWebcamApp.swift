import SwiftUI

public class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if SetupModel.needsFirstRunSetup {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Menu-bar agent: no Dock icon, no window at (login) launch.
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI may have created the main window already; close it so a
        // login launch is invisible until the user opens it from the menu.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.close()
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

public struct WAMCApplication: Scene {
    @StateObject private var model: AppModel
    @StateObject private var updater: AppUpdateController

    public init(startServices: Bool = true) {
        let model = AppModel(startServices: startServices)
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: AppUpdateController(
            enabled: startServices,
            isStreaming: { [weak model] in
                guard let model else { return false }
                return model.session.wantsStreaming || model.feedState != .idle
            },
            changes: model.objectWillChange.eraseToAnyPublisher()))
    }

    public var body: some Scene {
        Window("WAMC — Android Mac Camera", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .task { updater.startOnce() }
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            MenuContent(model: model, updater: updater)
        } label: {
            Label("WAMC", systemImage: model.connected ? "video.fill" : "video")
                .task { updater.startOnce() }
        }
    }
}

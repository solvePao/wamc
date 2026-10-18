import SwiftUI

public class AppDelegate: NSObject, NSApplicationDelegate {
    private let application: NSApplication
    private let needsSetup: @MainActor () -> Bool
    private let enqueue: (@escaping () -> Void) -> Void

    public override convenience init() {
        self.init(application: .shared, needsSetup: { SetupModel.needsFirstRunSetup })
    }

    init(application: NSApplication, needsSetup: @escaping @MainActor () -> Bool,
         enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.application = application
        self.needsSetup = needsSetup
        self.enqueue = enqueue
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if needsSetup() {
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            return
        }
        // Menu-bar agent: no Dock icon, no window at (login) launch.
        application.setActivationPolicy(.accessory)
        // SwiftUI may have created the main window already; close it so a
        // login launch is invisible until the user opens it from the menu.
        enqueue { [application] in
            for window in application.windows {
                window.close()
            }
            application.setActivationPolicy(.accessory)
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

    public init(preferences: UserDefaults = .standard, startServices: Bool = true) {
        let model = AppModel(preferences: preferences, startServices: startServices)
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: Self.makeUpdater(model: model, enabled: startServices))
    }

    @MainActor
    static func makeUpdater(model: AppModel, enabled: Bool,
                            makeDriver: (() -> AppUpdateDriving)? = nil) -> AppUpdateController {
        AppUpdateController(
            enabled: enabled,
            isStreaming: { [weak model] in
                guard let model else { return false }
                return model.session.wantsStreaming || model.feedState != .idle
            },
            changes: model.objectWillChange.eraseToAnyPublisher(), makeDriver: makeDriver)
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

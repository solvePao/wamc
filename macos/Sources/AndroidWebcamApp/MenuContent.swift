import SwiftUI
import AndroidWebcamCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    var updater: AppUpdateController? = nil

    var body: some View {
        StableMenuContent(model: model, updater: updater, snapshot: MenuSnapshot(model: model))
            .equatable()
    }
}

/// Only menu-relevant changes can invalidate native menu items. AppModel also
/// publishes live stats, which must not interrupt pointer tracking in a menu.
struct StableMenuContent: View, Equatable {
    let model: AppModel
    let updater: AppUpdateController?
    let snapshot: MenuSnapshot
    @Environment(\.openWindow) private var openWindow

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.updater === rhs.updater && lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        let commands = MenuCommands(model: model, windows: openWindow)
        Text(shortTitle(snapshot.sessionAction.status))
        Text(shortTitle(snapshot.sessionAction.sourceLabel))
        Text(shortTitle(snapshot.cameraStatus))
        Text(shortTitle(snapshot.cameraUsage))
        // Live stats stay in the window. Updating menu text while it is open
        // can rebuild native menu items and swallow clicks.
        Divider()
        Button("Open WAMC", action: commands.showWindow)
        Button(action: model.performSessionAction) {
            Label(snapshot.sessionAction.title, systemImage: snapshot.sessionAction.symbol)
        }
        .disabled(!snapshot.sessionAction.enabled)

        Menu("Camera") { cameraItems }

        Menu("Source") { sourceItems }

        Menu("Preferences") { preferenceItems }
        Menu("Developer tools") {
            Toggle("Use ADB transport", isOn: Binding(
                get: { snapshot.developmentADBEnabled }, set: { model.developmentADBEnabled = $0 }))
            if snapshot.developmentADBEnabled {
                sourceButton(snapshot.adb)
                Button("Set USB File Transfer", action: model.configureDeviceDefaultUsb)
            }
        }
        Divider()
        Button("Setup & Diagnostics", action: commands.showSetup)
        Menu("Troubleshooting") {
            Button("Check camera output", action: model.checkCameraOutput)
            Button("Camera Extension Settings", action: model.extensionManager.openSystemSettings)
        }
        Divider()
        if let updater { UpdateMenuItem(updater: updater) }
        Button("Quit WAMC", action: commands.quit)
            .keyboardShortcut("q")
    }

    var qualitySelection: Binding<QualityMode> {
        Binding(get: { snapshot.quality }, set: model.setQuality)
    }

    var automaticStreaming: Binding<Bool> {
        Binding(get: { snapshot.startStreamingAutomatically },
                set: { model.startStreamingAutomatically = $0 })
    }

    var loginEnabled: Binding<Bool> {
        Binding(get: { snapshot.launchAtLogin }, set: model.setLaunchAtLogin)
    }

    @ViewBuilder var cameraItems: some View {
            Picker("Quality", selection: qualitySelection) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Divider()
            Button(snapshot.facingBack ? "Use front camera" : "Use rear camera", action: model.switchCamera)
                .disabled(!snapshot.connected)
            Button("Rotate 90°", action: model.rotate).disabled(!snapshot.connected)
        }

    @ViewBuilder var sourceItems: some View {
            let commands = MenuCommands(model: model, windows: openWindow)
            sourceButton(snapshot.usb)
            if snapshot.developmentADBEnabled { sourceButton(snapshot.adb) }
            ForEach(snapshot.phones) { phone in
                sourceButton(phone.source)
            }
            ForEach(snapshot.manualSources, id: \.target.key) { source in
                sourceButton(source)
            }
            if snapshot.phones.isEmpty {
                Text(shortTitle(snapshot.wifiStatus))
            }
            Divider()
            Button("Refresh devices", action: model.refreshDevices)
            Button("More source options…", action: commands.showWindow)
        }

    @ViewBuilder var preferenceItems: some View {
            Toggle("Start streaming automatically", isOn: automaticStreaming)
            Toggle("Launch at login", isOn: loginEnabled)
            if snapshot.loginRequiresApproval {
                Button("Approve Launch at Login…", action: model.launchAtLogin.openLoginItemsSettings)
            }
        }
    private func sourceButton(_ source: MenuSnapshot.Source) -> some View {
        let selection = SourceSelection(model: model, target: source.target)
        return Button(action: selection.select) {
            Label(source.active ? "\(source.title) · Active" : source.title,
                  systemImage: source.selected ? "checkmark" : "circle")
        }
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 30 ? String(title.prefix(29)) + "…" : title
    }
}

struct MenuSnapshot: Equatable {
    struct Source: Equatable {
        let target: ConnectionTarget
        let title: String
        let selected: Bool
        let active: Bool

        @MainActor
        init(target: ConnectionTarget, title: String, model: AppModel) {
            self.target = target
            self.title = title
            selected = model.isSourceSelected(target)
            active = model.isSourceActive(target)
        }
    }

    struct Phone: Identifiable, Equatable {
        let source: Source
        var id: String { source.target.key }
    }

    let cameraStatus: String
    let cameraUsage: String
    let sessionAction: SessionActionSnapshot
    let connected: Bool
    let feedState: FeedState
    let connectionState: ConnectionState
    let selectedSource: ConnectionTarget
    let usb: Source
    let adb: Source
    let developmentADBEnabled: Bool
    let manualSources: [Source]
    let facingBack: Bool
    let quality: QualityMode
    let wifiStatus: String
    let phones: [Phone]
    let startStreamingAutomatically: Bool
    let launchAtLogin: Bool
    let loginRequiresApproval: Bool

    @MainActor
    init(model: AppModel) {
        cameraStatus = "Camera: \(model.cameraHealth.health.output.rawValue)"
        cameraUsage = model.cameraHealth.health.usageText
        sessionAction = model.sessionAction
        connected = model.connected
        feedState = model.feedState
        connectionState = model.connectionState
        selectedSource = model.selectedSource
        usb = Source(target: .usb(serial: nil), title: "USB accessory", model: model)
        adb = Source(target: .adb(serial: nil), title: "ADB (development)", model: model)
        developmentADBEnabled = model.developmentADBEnabled
        var addresses: [ConnectionTarget] = []
        if case .address = model.selectedSource { addresses.append(model.selectedSource) }
        if let active = model.connectionState.target, case .address = active,
           !addresses.contains(where: { $0.key == active.key }) { addresses.append(active) }
        manualSources = addresses.map { Source(target: $0, title: $0.label, model: model) }
        facingBack = model.facingBack
        quality = model.qualityMode
        wifiStatus = model.wifiStatusText
        phones = model.visibleWifiDevices.map {
            Phone(source: Source(target: .wifi($0),
                                 title: "\($0.displayName) · \(model.isTrusted($0) ? "Trusted phone" : "New phone")",
                                 model: model))
        }
        startStreamingAutomatically = model.startStreamingAutomatically
        launchAtLogin = model.launchAtLoginEnabled
        loginRequiresApproval = model.launchAtLoginRequiresApproval
    }
}

struct UpdateMenuItem: View {
    @ObservedObject var updater: AppUpdateController

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
        if updater.installationDeferred {
            Text("Update will install after streaming stops")
        }
    }
}

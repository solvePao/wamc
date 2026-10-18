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
        Text(shortTitle(snapshot.sessionAction.status))
        Text(shortTitle(snapshot.sessionAction.sourceLabel))
        Text(shortTitle(snapshot.cameraStatus))
        // Live stats stay in the window. Updating menu text while it is open
        // can rebuild native menu items and swallow clicks.
        Divider()
        Button("Open WAMC") { showWindow() }
        Button(action: model.performSessionAction) {
            Label(snapshot.sessionAction.title, systemImage: snapshot.sessionAction.symbol)
        }
        .disabled(!snapshot.sessionAction.enabled)

        Menu("Camera") {
            Picker("Quality", selection: Binding(get: { snapshot.quality }, set: model.setQuality)) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Divider()
            Button(snapshot.facingBack ? "Use front camera" : "Use rear camera", action: model.switchCamera)
                .disabled(!snapshot.connected)
            Button("Rotate 90°", action: model.rotate).disabled(!snapshot.connected)
        }

        Menu("Source") {
            sourceButton(snapshot.usb)
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
            Button("More source options…") { showWindow() }
        }

        Menu("Preferences") {
            Toggle("Start streaming automatically", isOn: Binding(
                get: { snapshot.startStreamingAutomatically },
                set: { model.startStreamingAutomatically = $0 }))
            Toggle("Launch at login", isOn: Binding(
                get: { snapshot.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if snapshot.loginRequiresApproval {
                Button("Approve Launch at Login…") { model.launchAtLogin.openLoginItemsSettings() }
            }
        }
        Divider()
        Button("Setup & Diagnostics") {
            model.setup.showSetup = true
            showWindow()
        }
        Menu("Troubleshooting") {
            Button("Camera Extension Settings") { model.extensionManager.openSystemSettings() }
            Button("Set USB File Transfer", action: model.configureDeviceDefaultUsb)
        }
        Divider()
        if let updater { UpdateMenuItem(updater: updater) }
        Button("Quit WAMC") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func sourceButton(_ source: MenuSnapshot.Source) -> some View {
        Button { model.selectSource(source.target) } label: {
            Label(source.active ? "\(source.title) · Active" : source.title,
                  systemImage: source.selected ? "checkmark" : "circle")
        }
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
    let sessionAction: SessionActionSnapshot
    let connected: Bool
    let feedState: FeedState
    let connectionState: ConnectionState
    let selectedSource: ConnectionTarget
    let usb: Source
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
        cameraStatus = model.virtualCameraActive ? "Virtual camera ready" : model.virtualCameraStatusText
        sessionAction = model.sessionAction
        connected = model.connected
        feedState = model.feedState
        connectionState = model.connectionState
        selectedSource = model.selectedSource
        usb = Source(target: .usb(serial: nil), title: "USB", model: model)
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

private struct UpdateMenuItem: View {
    @ObservedObject var updater: AppUpdateController

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
        if updater.installationDeferred {
            Text("Update will install after streaming stops")
        }
    }
}

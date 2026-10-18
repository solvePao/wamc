import SwiftUI
import AVFoundation
import AndroidWebcamCore

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var setup: SetupModel
    @ObservedObject private var camera: CameraExtensionManager
    @ObservedObject private var wifi: WifiDiscovery
    @ObservedObject private var diagnostics: StreamDiagnostics

    init(model: AppModel) {
        self.model = model
        setup = model.setup
        camera = model.extensionManager
        wifi = model.wifiDiscovery
        diagnostics = model.diagnostics
    }

    private var readiness: SetupReadiness {
        SetupReadiness.evaluate(installed: setup.installed, validPackage: setup.packageIssue == nil,
            extensionEnabled: camera.status == .active, sinkRegistered: setup.sinkRegistered,
            sendingFrames: model.virtualCameraSendingFrames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "video.badge.checkmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up WAMC").font(.title2.weight(.semibold))
                        Text("Your Android camera, ready for your Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
                Label(deliveryText, systemImage: readiness == .streaming ? "video.fill" : "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ControlSection(title: "Mac camera", symbol: "desktopcomputer") {
                        SetupRow(title: "Install in Applications", ready: setup.installed,
                                 detail: setup.installed ? "WAMC is installed in Applications." : "Install this copy before activating its camera extension.") {
                            if !setup.installed {
                                Button(setup.installing ? "Installing…" : "Install & Relaunch") { setup.installInApplications() }
                                    .disabled(setup.installing || setup.packageIssue != nil)
                            }
                        }
                        if let issue = setup.packageIssue { Text(issue).foregroundStyle(.red) }
                        if let error = setup.operationError { Text(error).foregroundStyle(.red) }
                        SetupRow(title: "Enable Android Camera", ready: camera.status == .active && setup.sinkRegistered,
                                 detail: cameraDetail) {
                            Button(cameraAction) { setup.activateCamera() }
                                .disabled(!setup.installed || setup.packageIssue != nil || camera.status == .activating || camera.status == .requiresRestart)
                        }
                        SetupRow(title: "Camera access", ready: setup.cameraAuthorization == .authorized,
                                 detail: "Allow WAMC to discover native webcams. Meeting apps request their own camera access.") {
                            if setup.cameraAuthorization != .authorized {
                                Button("Allow Camera Access") { setup.enableCameraAccess() }
                            }
                        }
                    }
                    Divider()
                    ControlSection(title: "Your phone", symbol: "iphone.gen3") {
                        SetupRow(title: "Connect your phone", ready: model.connected,
                                 detail: model.connected ? "Connected over \(model.transportLabel). Keep the camera running on your phone." : "Open WAMC on Android and allow its camera. Connect a USB data cable, or trust your phone on the same Wi-Fi.") {
                            Button("Refresh Phones") { model.refreshDevices() }
                        }
                        SetupRow(title: "USB connection", ready: DeviceDiscovery.adbPath() != nil,
                                 detail: DeviceDiscovery.adbPath() == nil ? "USB needs Android Platform Tools. Wi-Fi works without them." : "Platform Tools found. Unlock your phone and accept “Allow USB debugging” when prompted.") {
                            if DeviceDiscovery.adbPath() == nil {
                                Link("Get Platform Tools", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                            } else {
                                Button("Set File Transfer Mode") { model.configureDeviceDefaultUsb() }
                            }
                        }
                        SetupRow(title: "Wi-Fi connection", ready: !model.discoveredDevices.isEmpty || model.activeTransport == .wifi,
                                 detail: "\(wifi.statusText). Allow Local Network access, then select the phone and use Start stream in the main window.") {
                            Button("Local Network Settings") { setup.openPrivacy("Privacy_LocalNetwork") }
                        }
                    }
                    Divider()
                    ControlSection(title: "Automatic connection", symbol: "bolt") {
                        AutomationPreferences(model: model)
                        Button("Enable Recommended Defaults") {
                            model.startStreamingAutomatically = true
                            model.setLaunchAtLogin(true)
                            setup.enableCameraAccess()
                            setup.activateCamera()
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Choose Android Camera", systemImage: "web.camera")
                            .font(.headline)
                        Text("In FaceTime → Video or Photo Booth → Camera, select Android Camera. You can also select it in Zoom or Meet. The OBS logo means OBS Virtual Camera is selected.")
                        Text("macOS asks you to approve camera extensions and privacy access. WAMC checks again when you return from System Settings.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Check Again") { setup.refresh(); model.refreshDevices() }
                Spacer()
                Button("Later") { setup.showSetup = false }
                    .keyboardShortcut(.cancelAction)
                Button("Finish Setup") { setup.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.installed || setup.packageIssue != nil || camera.status != .active || !setup.sinkRegistered)
            }
            .padding(20)
        }
        .frame(width: 600, height: 640)
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refresh() }
    }

    private var cameraDetail: String {
        if camera.status == .active {
            return setup.sinkRegistered ? "Android Camera is enabled and its video input is registered." : "Enabled; waiting for the camera device to register. Try Install / Repair if this persists."
        }
        return camera.status.description + ". In Camera Extensions, turn on WAMC → Android Camera."
    }

    private var cameraAction: String {
        switch camera.status {
        case .requiresApproval, .disabled: return "Open Camera Extensions"
        case .activating: return "Installing…"
        case .requiresRestart: return "Restart Required"
        default: return "Install / Repair Camera"
        }
    }

    private var deliveryText: String {
        switch readiness {
        case .needsInstallation: return "Install WAMC to continue."
        case .invalidPackage: return "This copy needs a signing repair."
        case .needsExtension: return "Enable Android Camera to continue."
        case .waitingForSink: return "Waiting for the virtual camera's video input."
        case .waitingForPhone: return "Virtual camera ready; waiting for phone video."
        case .streaming: return "Sending phone video to Android Camera."
        }
    }
}

private struct SetupRow<Actions: View>: View {
    let title: String
    let ready: Bool
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .accessibilityLabel(ready ? "Ready" : "Needs attention")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
    }
}

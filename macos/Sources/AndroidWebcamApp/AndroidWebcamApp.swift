import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

@main
struct WAMCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WAMC — Wired Android Mac Camera") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 480)
        }
        MenuBarExtra("WAMC", systemImage: model.connected ? "video.fill" : "video") {
            MenuContent(model: model)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(model.connected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(model.connected ? "Connected" : "Disconnected")
                    .font(.headline)
                Spacer()
                Text(model.deviceLabel).foregroundStyle(.secondary)
            }

            PreviewView(renderer: model.renderer)
                .frame(minHeight: 300)
                .background(Color.black)
                .cornerRadius(8)

            Text(model.statusText)
            Text(model.diagnosticsText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.nativeWebcams.isEmpty {
                Label("Native USB webcam found: \(model.nativeWebcams.joined(separator: ", ")) — usable directly, no streaming needed.",
                      systemImage: "web.camera")
                    .font(.caption)
            }

            Picker("Quality", selection: $model.qualityMode) {
                ForEach(QualityMode.allCases) { mode in
                    Text("\(mode.label) · 30 FPS").tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button(model.connected ? "Disconnect" : "Connect") {
                    model.connected ? model.disconnect() : model.connect()
                }
                Button("Start camera") { model.sendStart() }
                    .disabled(!model.connected)
                Button("Stop camera") { model.sendStop() }
                    .disabled(!model.connected)
                Button(model.facingBack ? "Use front camera" : "Use rear camera") {
                    model.switchCamera()
                }
                .disabled(!model.connected)
                Button("Rotate 90°") { model.rotate() }
                    .disabled(!model.connected)
                Spacer()
                Button("Refresh devices") { model.refreshDevices() }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.virtualCameraActive ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.virtualCameraStatusText)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("Select virtual camera in FaceTime, Photo Booth, Zoom, or Meet to use phone feed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Camera Extension Settings") {
                    model.extensionManager.openSystemSettings()
                }
            }
        }
        .padding(16)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.connected ? "Connected — \(model.deviceLabel)" : "Not connected")
        Text(model.diagnosticsText)
        Divider()
        Text(model.virtualCameraStatusText)
        Button("Camera Extension Settings") {
            model.extensionManager.openSystemSettings()
        }
        Button("Set Phone Default USB to File Transfer") {
            model.configureDeviceDefaultUsb()
        }
        Divider()
        Button(model.connected ? "Disconnect" : "Connect") {
            model.connected ? model.disconnect() : model.connect()
        }
        Button("Start camera") { model.sendStart() }.disabled(!model.connected)
        Button("Stop camera") { model.sendStop() }.disabled(!model.connected)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

import SwiftUI
import AVFoundation

/// One presentation of the same evidence in preview and setup diagnostics.
struct CameraHealthView: View {
    let model: AppModel
    @ObservedObject private var monitor: VirtualCameraHealthMonitor

    init(model: AppModel) {
        self.model = model
        monitor = model.cameraHealth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Phone feed: \(model.feedState == .live ? "Live" : "No live feed")",
                  systemImage: model.feedState == .live ? "video.fill" : "video.slash")
            Label("Camera output: \(monitor.health.output.rawValue)",
                  systemImage: monitor.health.output == .ready ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(monitor.health.output == .ready ? Color.green : Color.primary)
            Text("App usage: \(monitor.health.usageText)")
            Text(monitor.health.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if monitor.health.output == .failed || monitor.health.output == .unavailable {
                HStack {
                    Button("Check again", action: checkAgain)
                    if model.setup.cameraAuthorization != .authorized {
                        Button("Allow Camera Access", action: allowCameraAccess)
                    }
                    Button("Setup & Diagnostics", action: showDiagnostics)
                }
                .font(.caption)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func checkAgain() { model.checkCameraOutput() }
    func allowCameraAccess() { model.setup.enableCameraAccess() }
    func showDiagnostics() { model.setup.showSetup = true }
}

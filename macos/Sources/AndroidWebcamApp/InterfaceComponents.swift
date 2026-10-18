import SwiftUI

/// A status always includes text, so color is never the only signal.
struct StatusBadge: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }
}

struct ControlSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CameraControls: View, Equatable {
    let connected: Bool
    let facingBack: Bool
    let quality: QualityMode
    let setQuality: (QualityMode) -> Void
    let switchCamera: () -> Void
    let rotate: () -> Void

    // Actions belong to the same AppModel for the lifetime of this window.
    // Compare value snapshots so 1 Hz diagnostics cannot rebuild an open picker.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connected == rhs.connected && lhs.facingBack == rhs.facingBack
            && lhs.quality == rhs.quality
    }

    var body: some View {
        ControlSection(title: "Camera", symbol: "video") {
            HStack(spacing: 8) {
                Button(action: switchCamera) {
                    Label(facingBack ? "Use front" : "Use rear", systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .wamcActionStyle()
                .help(facingBack ? "Switch to the front camera" : "Switch to the rear camera")
                Button(action: rotate) {
                    Label("Rotate", systemImage: "rotate.right")
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .wamcActionStyle()
                .help("Rotate the camera 90°")
                .accessibilityLabel("Rotate camera 90 degrees")
            }
            .controlSize(.regular)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .disabled(!connected)

            Picker("Quality", selection: Binding(get: { quality }, set: setQuality)) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 36)
            Text("All quality modes use 30 FPS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ConnectedCameraControlsPreview: PreviewProvider {
    static var previews: some View {
        GlassControlGroup {
            CameraControls(connected: true, facingBack: false, quality: .best, setQuality: { _ in },
                           switchCamera: {}, rotate: {})
                .padding(20)
                .frame(width: 320)
                .preferredColorScheme(.light)
        }
        .previewDisplayName("Camera controls · connected")
    }
}

struct DisconnectedCameraControlsPreview: PreviewProvider {
    static var previews: some View {
        GlassControlGroup {
            CameraControls(connected: false, facingBack: false, quality: .best, setQuality: { _ in },
                           switchCamera: {}, rotate: {})
                .padding(20)
                .frame(width: 320)
                .preferredColorScheme(.dark)
        }
        .previewDisplayName("Camera controls · disconnected")
    }
}

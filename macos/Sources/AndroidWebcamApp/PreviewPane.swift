import SwiftUI

struct PreviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var diagnostics: StreamDiagnostics
    @State private var showDiagnostics = false

    init(model: AppModel) {
        self.model = model
        diagnostics = model.diagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.identityMismatch {
                Label("This Wi-Fi phone's identity could not be verified. It was disconnected. Forget it in Connections if you don't recognize it.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            ZStack {
                if model.feedState == .live {
                    PreviewView(renderer: model.renderer)
                        .accessibilityLabel("Phone camera preview")
                } else {
                    DisconnectedPreview(connected: model.connected, feedState: model.feedState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 200)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if model.connected {
                    Text(model.diagnosticsText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            CameraHealthView(model: model)

            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.virtualCameraStatusText)
                        Text(model.diagnosticsText)
                        Text("Frames: \(model.stats.framesReceived) · Keyframes: \(model.stats.keyframesReceived) · Decode errors: \(model.stats.decodeErrors)")
                        Text("Processing time measures work on this Mac, excluding capture and network transit.")
                            .foregroundStyle(.secondary)
                        Button("Setup & Diagnostics") { model.setup.showSetup = true }
                    }
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct DisconnectedPreview: View {
    var connected = false
    var feedState: FeedState = .idle

    private var guidance: String {
        switch feedState {
        case .starting: return "Starting camera…"
        case .updating: return "Applying quality…"
        case .stalled: return "No video arriving. Check the phone, or stop and start the stream."
        default:
            return connected ? "Phone connected. Press Start stream to receive video."
                : "Choose USB or a Wi-Fi phone,\nthen press Start stream."
        }
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityHidden(true)
            Text("No feed")
                .font(.title3.weight(.medium))
            Text(guidance)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07))
    }
}

struct DisconnectedCanvasPreview: PreviewProvider {
    static var previews: some View {
        DisconnectedPreview()
            .frame(width: 520, height: 380)
            .previewDisplayName("Disconnected canvas")
    }
}

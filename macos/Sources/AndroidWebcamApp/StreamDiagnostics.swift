import Combine
import AndroidWebcamCore

/// Display-only updates never invalidate AppModel's interactive controls.
@MainActor
final class StreamDiagnostics: ObservableObject {
    @Published var stats = StreamStats()
}

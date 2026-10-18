import AndroidWebcamCore

/// UI state reflects decoded video, independently of the transport socket.
enum FeedState: Equatable {
    case idle, starting, live, updating, stalled
}

/// Start and live quality changes use the same negotiated profile.
enum StreamCommand {
    static func start(quality: QualityMode, transport: TransportKind?) -> [(String, String)] {
        let wifi = transport == .wifi
        var fields = [
            ("cmd", "start"), ("width", "\(quality.width)"), ("height", "\(quality.height)"),
            ("fps", "30"), ("quality", quality.rawValue), ("codec", "auto"),
            ("codecs", "avc,hevc"), ("configV2", "1"), ("transport", wifi ? "wifi" : "usb"),
        ]
        if wifi { fields.append(("latency", "low")) }
        return fields
    }
}

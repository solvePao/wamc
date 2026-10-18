import Foundation
import CoreVideo
import AVFoundation
import AndroidWebcamCore
import AndroidWebcamProtocol

/// Quality tiers sent to the phone; resolution travels alongside.
enum QualityMode: String, CaseIterable, Identifiable {
    case best, high, balanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "Best · auto"
        case .high: return "1080p · high"
        case .balanced: return "720p · balanced"
        }
    }
    var width: Int { self == .balanced ? 1280 : 1920 }
    var height: Int { self == .balanced ? 720 : 1080 }
}

/// Orchestrates discovery → adb forward → receive → decode → preview/extension.
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var nativeWebcams: [String] = []
    @Published var connected = false
    @Published var deviceInfo: [String: String] = [:]
    @Published var stats = StreamStats()
    @Published var statusText = "Plug in your Samsung phone with USB to begin."
    @Published var facingBack = true
    /// Best = HEVC/VBR ceiling when negotiated, else max-rate AVC.
    @Published var qualityMode: QualityMode = .best
    @Published var codecLabel = "H.264"
    @Published var rotationQuarterTurns = 0

    let renderer = PreviewRenderer()
    let extensionManager = CameraExtensionManager()
    private let receiver = USBReceiver()
    private let decoder = H264Decoder()
    private let frameQueue = LatestFrameQueue()
    private let extensionBridge = ExtensionBridge()
    private var displayTimer: Timer?
    private let streamLock = NSLock()
    private var lastConfigDesc: String?

    private func updateLastConfigDesc(_ desc: String) -> Bool {
        streamLock.lock()
        defer { streamLock.unlock() }
        if lastConfigDesc == desc { return false }
        lastConfigDesc = desc
        return true
    }

    private func resetLastConfigDesc() {
        streamLock.lock()
        defer { streamLock.unlock() }
        lastConfigDesc = nil
    }

    init() {
        receiver.onConfigV2 = { [weak self] config in
            guard let self else { return }
            let desc = "\(config.width)x\(config.height)@\(config.fps):\(config.rotation)"
            _ = self.updateLastConfigDesc(desc)
            self.decoder.configure(withV2: config)
            let codec = config.codec == WireProtocol.codecHEVC ? "HEVC" : "H.264"
            Task { @MainActor in
                self.rotationQuarterTurns = config.rotation
                self.codecLabel = codec
                self.statusText = "Receiving \(codec) \(config.width)×\(config.height) @ \(config.fps) FPS · \(config.rotation * 90)°"
            }
        }
        receiver.onConfig = { [weak self] config in
            guard let self else { return }
            let desc = "\(config.width)x\(config.height)@\(config.fps):\(config.rotation)"
            guard self.updateLastConfigDesc(desc) else { return }
            self.decoder.configure(with: config)
            Task { @MainActor in
                self.rotationQuarterTurns = config.rotation
                self.codecLabel = "H.264"
                self.statusText = "Receiving H.264 \(config.width)×\(config.height) @ \(config.fps) FPS · \(config.rotation * 90)°"
            }
        }
        receiver.onVideo = { [weak self] data, pts, isKey in
            guard let self else { return }
            Task { @MainActor in self.stats.recordFrame(bytes: data.count, isKeyframe: isKey) }
            self.decoder.decode(annexB: data, ptsUs: pts, isKeyframe: isKey)
        }
        receiver.onHello = { [weak self] info in
            Task { @MainActor in
                self?.deviceInfo = info
                self?.objectWillChange.send()
            }
        }
        receiver.onConnectionChange = { [weak self] isUp in
            Task { @MainActor in
                guard let self else { return }
                self.connected = isUp
                if isUp {
                    self.stats.connectedSince = Date()
                    self.statusText = "Connected — waiting for video…"
                    // Capability announcement so the phone picks the best
                    // codec itself; never starts streaming on its own.
                    self.receiver.sendControl([
                        ("cmd", "hello"),
                        ("codecs", "avc,hevc"),
                        ("configV2", "1"),
                    ])
                    self.receiver.sendControl([("cmd", "requestKeyframe")])
                } else {
                    self.stats.connectedSince = nil
                    self.statusText = "Disconnected. Reconnecting…"
                }
            }
        }
        decoder.onPixelBuffer = { [weak self] pixelBuffer, _ in
            self?.frameQueue.enqueue(pixelBuffer)
        }
        decoder.onError = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stats.decodeErrors += 1
                self.receiver.sendControl([("cmd", "requestKeyframe")])
            }
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let frame = self.frameQueue.dequeueLatest() else { return }
                // Decode-only fast path: rotation already happened on-device
                // (CONFIG rotation 0), so forward the buffer untouched.
                let out = self.rotationQuarterTurns == 0 ? frame
                    : FrameRotation.rotate(frame, quarterTurns: self.rotationQuarterTurns)
                self.renderer.enqueue(out)
                self.extensionBridge.send(out)
                self.objectWillChange.send()
            }
        }
        refreshDevices()
        connect()
    }

    func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DeviceDiscovery.listAndroidDevices()
            let uvc = DeviceDiscovery.nativeUVCWebcams()
            if let first = found.first(where: { $0.state == "device" }) {
                DeviceDiscovery.configureDefaultUsbMode(serial: first.id)
            }
            Task { @MainActor in
                self?.devices = found
                self?.nativeWebcams = uvc
            }
        }
    }

    func configureDeviceDefaultUsb() {
        DispatchQueue.global(qos: .userInitiated).async {
            DeviceDiscovery.configureDefaultUsbMode()
        }
    }

    func connect() {
        DeviceDiscovery.configureDefaultUsbMode()
        DeviceDiscovery.forwardPort()
        receiver.start()
        statusText = "Connecting through USB…"
    }

    func disconnect() {
        receiver.stop()
        DeviceDiscovery.removeForward()
        decoder.invalidate()
        frameQueue.clear()
        resetLastConfigDesc()
        connected = false
        statusText = "Disconnected."
    }

    func sendStart() {
        codecLabel = "H.264" // replaced by CONFIG once the stream describes itself
        resetLastConfigDesc()
        receiver.sendControl([
            ("cmd", "start"),
            ("width", "\(qualityMode.width)"),
            ("height", "\(qualityMode.height)"),
            ("fps", "30"),
            ("quality", qualityMode.rawValue),
            ("codec", "auto"),
            ("codecs", "avc,hevc"),
            ("configV2", "1"),
        ])
    }

    func sendStop() { receiver.sendControl([("cmd", "stop")]) }

    func switchCamera() {
        facingBack.toggle()
        receiver.sendControl([("cmd", "setFacing"), ("facing", facingBack ? "back" : "front")])
    }

    /// Asks the phone to rotate; it echoes back in CONFIG and both sides turn.
    func rotate() {
        receiver.sendControl([("cmd", "rotate")])
    }

    var deviceLabel: String {
        if let model = deviceInfo["model"] { return model }
        return devices.first?.model ?? "No phone detected"
    }

    var diagnosticsText: String {
        String(format: "%@ · %.0f FPS · %.1f Mbps", codecLabel, stats.fps, stats.bitrateMbps)
    }

    var virtualCameraActive: Bool {
        extensionBridge.available
    }

    var virtualCameraStatusText: String {
        if extensionBridge.available {
            return "Virtual Camera: Active (\(extensionBridge.connectedStreamName ?? "Connected"))"
        }
        return "Virtual Camera: Enable in System Settings > Camera Extensions"
    }
}

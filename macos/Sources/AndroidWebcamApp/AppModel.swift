import Foundation
import CoreVideo
import AVFoundation
import Network
import Combine
import AndroidWebcamCore
import AndroidWebcamProtocol
import AccessoryUSB

protocol DeviceInventory: Sendable {
    func listAndroidDevices() -> [AndroidDevice]
    func listDevelopmentDevices() -> [AndroidDevice]
    func nativeUVCWebcams() -> [String]
    func configureDefaultUsbMode(serial: String?) -> Bool
}

extension DeviceInventory {
    func listDevelopmentDevices() -> [AndroidDevice] { [] }
}

struct SystemDeviceInventory: DeviceInventory {
    func listAndroidDevices() -> [AndroidDevice] {
        AccessoryDevice.discover().map { AndroidDevice(id: $0.id, model: $0.name, state: "device") }
    }
    func listDevelopmentDevices() -> [AndroidDevice] { DeviceDiscovery.listAndroidDevices() }
    func nativeUVCWebcams() -> [String] { DeviceDiscovery.nativeUVCWebcams() }
    func configureDefaultUsbMode(serial: String?) -> Bool {
        DeviceDiscovery.configureDefaultUsbMode(serial: serial)
    }
}

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

/// Orchestrates discovery → connect (USB accessory, or Wi-Fi via
/// Bonjour) → decode → preview/extension. USB is preferred; exactly one
/// transport is active at a time, owned by ConnectionController.
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var nativeWebcams: [String] = []
    @Published private(set) var platformToolsAvailable = false
    @Published private(set) var usbModeMessage: String?
    @Published private(set) var configuringUsbMode = false
    let connection: ConnectionController
    lazy var session = SessionModel(preferences: preferences, connection: connection)
    var connected: Bool { connection.state.isConnected }
    var connectionState: ConnectionState { connection.state }
    @Published private(set) var feedState: FeedState = .idle {
        didSet { updateCameraHealth() }
    }
    let cameraHealth: VirtualCameraHealthMonitor
    private var cameraHealthEnabled = false
    private var cameraHealthObservation: AnyCancellable?
    private var wifiStatusObservation: AnyCancellable?
    @Published var deviceInfo: [String: String] = [:]
    let diagnostics = StreamDiagnostics()
    private(set) var stats: StreamStats {
        get { diagnostics.stats }
        set { diagnostics.stats = newValue }
    }
    /// Frames accumulate without UI notifications and flush only to the
    /// diagnostics views at ≤1 Hz. Open controls never observe this publisher.
    private var liveStats = StreamStats()
    private var statsGate = PublishGate(interval: 1.0)
    @Published var developmentADBEnabled = false {
        didSet {
            preferences.set(developmentADBEnabled, forKey: "wamc.developmentADBEnabled")
            if !developmentADBEnabled, case .adb = selectedSource {
                session.stop()
                session.select(.usb(serial: nil))
            }
            refreshDevices()
        }
    }
    @Published private(set) var developmentDevices: [AndroidDevice] = []
    @Published var statusText = "Plug in your Samsung phone with USB, or open WAMC on the phone on the same Wi-Fi."
    /// Phone streams the front camera by default; this mirrors that.
    @Published var facingBack = false
    /// Best = HEVC/VBR ceiling when negotiated, else max-rate AVC.
    @Published private(set) var qualityMode: QualityMode = .best
    @Published var codecLabel = "H.264"
    @Published var rotationQuarterTurns = 0
    /// Wi-Fi (Bonjour) devices currently visible on the LAN.
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var wifiStatusText = "Wi-Fi discovery off"
    /// Transport of the live (or dialling) connection, if any.
    var activeTransport: TransportKind? { connection.state.target?.transport }
    /// Device the Wi-Fi connection was dialled for (identity check).
    var wifiDevice: DiscoveredDevice? {
        if case .wifi(let device) = connection.state.target { return device }
        return nil
    }
    /// Set when a Wi-Fi HELLO id does not match the advertised TXT id.
    var identityMismatch: Bool { connection.identityMismatch }
    /// Launch-at-login mirrors (real SMAppService status, refreshed).
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginRequiresApproval = false
    /// Manual IP fallback for networks that block mDNS (window only).
    @Published var manualAddress = ""
    /// Preview rendering pauses when the window is hidden; the virtual
    /// camera feed (extension bridge) keeps flowing in the background.
    var previewVisible = true

    let renderer = PreviewRenderer()
    let setup: SetupModel
    var extensionManager: CameraExtensionManager { setup.extensionManager }
    let wifiDiscovery: WifiDiscovery
    let trustedStore: TrustedDeviceStore
    let launchAtLogin: LaunchAtLogin
    private let preferences: UserDefaults
    private let decoder: H264Decoding
    private let deviceInventory: DeviceInventory
    private let frameQueue = LatestFrameQueue()
    private let extensionBridge: ExtensionBridge
    private var lastReportedBridgeAvailability: Bool?
    private var extensionStatusObservation: AnyCancellable?
    private var connectionObservation: AnyCancellable?
    private var sessionObservation: AnyCancellable?
    private let keyframeWatchdog = KeyframeWatchdog()
    private let now: () -> Date
    private var watchdogTimer: Timer?
    private var displayTimer: Timer?
    private let frameContexts = StreamFrameContextTracker()
    private var pollInProgress = false
    private var lastFrameAt: TimeInterval?
    private var phoneGeneration: String?
    private var awaitingGeneration = false
    private var receivedConfigV2 = false
    private var qualityTask: Task<Void, Never>?
    private var inFlightQuality: QualityMode?
    private var receivedDescription = ""
    /// Frame arrival times (host clock) keyed by phone pts, for the
    /// arrival→decode→bridge processing metric. Bounded, oldest evicted.
    private var arrivalByPts: [Int64: Date] = [:]
    private var arrivalOrder: [Int64] = []

    /// Starts app-owned timers and external services when running the app.
    /// Tests can build view state without starting Bonjour, setup polling, or ADB.
    init(preferences: UserDefaults = .standard, startServices: Bool = true, connection: ConnectionController? = nil,
         decoder: H264Decoding? = nil, extensionBridge: ExtensionBridge? = nil,
         deviceInventory: DeviceInventory = SystemDeviceInventory(),
         setupModel: SetupModel? = nil, loginItem: LaunchAtLogin? = nil,
         cameraHealthMonitor: VirtualCameraHealthMonitor? = nil,
         discovery: WifiDiscovery? = nil, timerScheduler: AppTimerScheduling = AppTimerScheduler(),
         now: @escaping () -> Date = Date.init) {
        cameraHealth = cameraHealthMonitor ?? VirtualCameraHealthMonitor()
        self.preferences = preferences
        self.developmentADBEnabled = preferences.bool(forKey: "wamc.developmentADBEnabled")
        trustedStore = TrustedDeviceStore(preferences: preferences)
        launchAtLogin = loginItem ?? LaunchAtLogin(defaults: preferences)
        wifiDiscovery = discovery ?? WifiDiscovery()
        self.now = now
        self.connection = connection ?? ConnectionController()
        self.decoder = decoder ?? H264Decoder()
        self.extensionBridge = extensionBridge ?? ExtensionBridge()
        self.deviceInventory = deviceInventory
        setup = setupModel ?? SetupModel(preferences: preferences)
        cameraHealthEnabled = startServices
        setup.hasVerifiedVideo = { [weak self] in
            guard let self else { return false }
            return self.connected && self.feedState == .live && self.virtualCameraSendingFrames
                && self.cameraHealth.health.output == .ready
        }
        setup.onRegistrationAvailable = { [weak self] in self?.checkCameraOutput() }
        cameraHealthObservation = cameraHealth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        let activeConnection = self.connection
        extensionStatusObservation = setup.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        connectionObservation = activeConnection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        session.endpointForDevice = { [weak self] phone in self?.wifiDiscovery.endpoint(for: phone) }
        session.isTrusted = { [weak self] phone in self?.isTrusted(phone) == true }
        session.trustDevice = { [weak self] phone in self?.trustedStore.trust(phone.id) }
        session.onStartCamera = { [weak self] in self?.sendStart() }
        sessionObservation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        activeConnection.onStateChange = { [weak self] state, message in
            guard let self else { return }
            self.session.connectionChanged(state)
            if !state.isConnected {
                self.resetStreamState()
                self.deviceInfo = [:]
                self.phoneGeneration = nil
            } else {
                let since = Date()
                self.liveStats.connectedSince = since
                self.stats.connectedSince = since
            }
            self.statusText = message
        }
        activeConnection.onHello = { [weak self] info, firstHello in
            guard let self else { return }
            let generation = info["gen"]
            if generation != self.phoneGeneration {
                self.resetDecoderState()
                self.phoneGeneration = generation
                self.awaitingGeneration = false
                if self.feedState != .idle { self.keyframeWatchdog.noteConfig(now: now()) }
            }
            self.deviceInfo = info
            if firstHello {
                self.connection.sendControl([("cmd", "requestKeyframe")])
                self.session.connectionReady()
            }
        }
        activeConnection.onStreamEvent = { [weak self] event in self?.receiveStreamEvent(event) }
        self.decoder.onPixelBuffer = { [weak self] pixels, pts, context in
            DispatchQueue.main.async {
                guard let self, self.connected, self.frameContexts.accepts(context) else { return }
                self.keyframeWatchdog.noteKeyframe(now: now())
                let upright = FrameRotation.rotate(pixels, quarterTurns: context.rotation)
                self.frameQueue.enqueue(upright, context: context)
                if let arrived = self.arrivalByPts.removeValue(forKey: pts) {
                    self.arrivalOrder.removeAll { $0 == pts }
                    self.liveStats.recordProcessing(ms: Date().timeIntervalSince(arrived) * 1000)
                }
                self.pumpLatestFrame()
            }
        }
        self.decoder.onError = { [weak self] context in
            DispatchQueue.main.async {
                guard let self, self.connected, self.frameContexts.accepts(context) else { return }
                self.liveStats.decodeErrors += 1
                self.stats.decodeErrors = self.liveStats.decodeErrors
                self.connection.sendControl([("cmd", "requestKeyframe")])
            }
        }
        wifiStatusObservation = wifiDiscovery.$statusText.sink { [weak self] status in
            guard let self, self.wifiStatusText != status else { return }
            self.wifiStatusText = status
        }
        wifiDiscovery.onDevicesChanged = { [weak self] found in
            Task { @MainActor in
                guard let self else { return }
                // Guarded sets: an unconditional publish here rebuilds the
                // open menu on every Bonjour update, even if nothing changed.
                if self.discoveredDevices != found { self.discoveredDevices = found }
                let wifiStatus = self.wifiDiscovery.statusText
                if self.wifiStatusText != wifiStatus { self.wifiStatusText = wifiStatus }
                self.session.discovered(usb: self.devices, wifi: found)
            }
        }
        if startServices {
            displayTimer = timerScheduler.repeating(every: 1.0 / 60) {
                [weak self] _ in
                Task { @MainActor in self?.pumpLatestFrame() }
            }
            wifiDiscovery.start()
            launchAtLogin.registerByDefaultIfNeeded()
            syncLaunchAtLogin()
            // Ask for the virtual camera now: nothing requested activation, so
            // FaceTime never saw "Android Camera" while the badge claimed Active.
            setup.start()
            refreshDevices()
            watchdogTimer = timerScheduler.repeating(every: 2.5) {
                [weak self] _ in Task { @MainActor in self?.pollDevices() }
            }
        }
    }

    /// Wrap the newest decoded frame once and share it with the preview
    /// (when visible) and the extension bridge (always). Called immediately
    /// on decode and on the 60 Hz fallback timer.
    private func pumpLatestFrame() {
        checkFeedFreshness()
        updateCameraHealth()
        maybeRequestKeyframe()
        guard connected, let frame = frameQueue.dequeueLatestFrame(),
              let context = frame.context, frameContexts.accepts(context) else { return }
        let out = frame.pixels
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        if feedState != .live {
            feedState = .live
            statusText = receivedDescription.isEmpty ? "Receiving video." : receivedDescription
            let sentQuality = inFlightQuality
            inFlightQuality = nil
            if let sentQuality, sentQuality != qualityMode { scheduleQualityChange() }
        }
        if previewVisible, let sample = makeImageSampleBuffer(out) {
            renderer.enqueue(sample)
        }
        // The virtual camera publishes one fixed format: normalize before
        // bridging so a size change never wraps pixels in a wrong description.
        let bridgePixels = normalizedBridgePixels(out)
        guard let bridgeSample = makeImageSampleBuffer(bridgePixels) else { return }
        extensionBridge.send(bridgeSample)
        // Readiness changes matter to menus; individual frames and statistics
        // do not. Publish only when the bridge becomes available/unavailable.
        if lastReportedBridgeAvailability != extensionBridge.available {
            lastReportedBridgeAvailability = extensionBridge.available
            objectWillChange.send()
        }
    }

    /// Re-asks for an IDR while the decoder is still waiting on one after a
    /// CONFIG or transport start. Throttled inside the watchdog; silent on
    /// the first attempt so a normal join shows no flicker.
    private func maybeRequestKeyframe() {
        guard connected, feedState != .idle else { return }
        if keyframeWatchdog.requestDue(now: now()) {
            connection.sendControl([("cmd", "requestKeyframe")])
            if keyframeWatchdog.attempts >= 2 {
                let waiting = "Waiting for keyframe — requesting recovery…"
                if statusText != waiting { statusText = waiting }
            }
        }
        if keyframeWatchdog.timedOut(now: now()) {
            if feedState != .stalled { feedState = .stalled }
            inFlightQuality = nil
            let timeout = "Keyframe timeout — open WAMC on the phone or reconnect the camera."
            if statusText != timeout { statusText = timeout }
        }
    }

    // MARK: - Trust

    func isTrusted(_ device: DiscoveredDevice) -> Bool {
        trustedStore.isTrusted(device.id)
    }

    func forgetDevice(_ device: DiscoveredDevice) {
        trustedStore.untrust(device.id)
        if wifiDevice?.id == device.id { stopSession() }
        objectWillChange.send()
    }

    // MARK: - Launch at login

    func syncLaunchAtLogin() {
        launchAtLogin.refresh()
        // Guarded: this runs on the 2.5 s watchdog, and same-value sets
        // would still publish and rebuild an open menu for no reason.
        if launchAtLoginEnabled != launchAtLogin.isEnabled {
            launchAtLoginEnabled = launchAtLogin.isEnabled
        }
        if launchAtLoginRequiresApproval != launchAtLogin.requiresApproval {
            launchAtLoginRequiresApproval = launchAtLogin.requiresApproval
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin.setEnabled(enabled)
        syncLaunchAtLogin()
    }

    // MARK: - Discovery / watchdog

    func refreshDevices() {
        wifiDiscovery.refresh()
        pollDevices()
    }

    func recoverSetup() {
        setup.refresh()
        wifiDiscovery.refresh(recoverOnly: true)
        pollDevices()
        checkCameraOutput()
    }

    func configureDeviceDefaultUsb() {
        guard developmentADBEnabled else { return }
        let serial = developmentDevices.first(where: { $0.state == "device" })?.id
        guard !configuringUsbMode else { return }
        guard let serial else {
            usbModeMessage = "Connect and authorize a USB debugging phone before changing its USB mode."
            return
        }
        configuringUsbMode = true
        usbModeMessage = "Setting File Transfer mode…"
        let inventory = deviceInventory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = inventory.configureDefaultUsbMode(serial: serial)
            Task { @MainActor in
                guard let self else { return }
                self.configuringUsbMode = false
                self.usbModeMessage = succeeded ? "File Transfer mode enabled."
                    : "Could not change USB mode. Unlock the phone and choose File Transfer in its USB settings."
            }
        }
    }

    /// Automatic selection prefers USB. A manual selection owns its transport
    /// until it is disconnected or fails, even while a cable is attached.
    private func pollDevices() {
        syncLaunchAtLogin()
        let toolsAvailable = developmentADBEnabled && DeviceDiscovery.adbPath() != nil
        if platformToolsAvailable != toolsAvailable { platformToolsAvailable = toolsAvailable }
        let wifiStatus = wifiDiscovery.statusText
        if wifiStatusText != wifiStatus { wifiStatusText = wifiStatus }
        guard !pollInProgress else { return }
        pollInProgress = true
        let inventory = deviceInventory
        let includeADB = developmentADBEnabled
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = inventory.listAndroidDevices()
            let development = includeADB ? inventory.listDevelopmentDevices() : []
            let uvc = inventory.nativeUVCWebcams()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInProgress = false
                if self.developmentDevices != development { self.developmentDevices = development }
                self.connection.updateUSBReadiness(development)
                if self.devices != found { self.devices = found }
                if self.nativeWebcams != uvc { self.nativeWebcams = uvc }
                self.connection.updateAvailableTargets(
                    found.map { .usb(serial: $0.id) } + development.map { .adb(serial: $0.id) } + self.discoveredDevices.map { .wifi($0) })
                if case .connected(.usb(let serial)) = self.connectionState,
                   !found.contains(where: { $0.id == serial && $0.state == "device" }) {
                    self.connection.usbWasRemoved()
                }
                self.session.discovered(usb: found, wifi: self.discoveredDevices)
            }
        }
    }

    private func resetDecoderState() {
        frameContexts.resetConfiguration()
        decoder.invalidate()
        frameQueue.clear()
        receivedConfigV2 = false
        arrivalByPts.removeAll()
        arrivalOrder.removeAll()
        keyframeWatchdog.reset()
        lastFrameAt = nil
        renderer.clear()
        if feedState == .live { feedState = .starting }
    }

    /// Invalidates retained pixels and delayed decoder callbacks on every teardown.
    private func resetStreamState() {
        frameContexts.advanceConnection()
        resetDecoderState()
        qualityTask?.cancel()
        qualityTask = nil
        inFlightQuality = nil
        awaitingGeneration = false
        receivedDescription = ""
        liveStats = StreamStats()
        stats = StreamStats()
        feedState = .idle
    }

    var canStartCamera: Bool { connected && (feedState == .idle || feedState == .stalled) }

    func sendStart() {
        guard canStartCamera else { return }
        startStream(updatingQuality: false)
    }

    func setQuality(_ mode: QualityMode) {
        guard mode != qualityMode else { return }
        qualityMode = mode
        if feedState != .idle {
            scheduleQualityChange()
        }
    }

    private func scheduleQualityChange() {
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.connected, self.inFlightQuality == nil else { return }
            self.startStream(updatingQuality: true)
        }
    }

    private func startStream(updatingQuality: Bool) {
        guard connected else { return }
        resetDecoderState()
        awaitingGeneration = phoneGeneration != nil
        inFlightQuality = qualityMode
        liveStats = StreamStats()
        liveStats.connectedSince = Date()
        stats = liveStats
        feedState = updatingQuality ? .updating : .starting
        statusText = updatingQuality ? "Applying quality…" : "Starting camera…"
        keyframeWatchdog.noteConfig(now: now())
        connection.sendControl(StreamCommand.start(quality: qualityMode, transport: activeTransport))
    }

    func switchCamera() {
        guard connected else { return }
        facingBack.toggle()
        connection.sendControl([("cmd", "setFacing"), ("facing", facingBack ? "back" : "front")])
    }

    func rotate() {
        guard connected else { return }
        connection.sendControl([("cmd", "rotate")])
    }

    private func checkFeedFreshness() {
        guard feedState == .live, let lastFrameAt,
              ProcessInfo.processInfo.systemUptime - lastFrameAt >= 1 else { return }
        feedState = .stalled
        renderer.clear()
        statusText = "No feed — check the phone or stop and start the stream."
    }

    private func receiveStreamEvent(_ event: StreamReceiver.Event) {
        guard connected, !awaitingGeneration else { return }
        switch event {
        case .configV2(let config):
            receivedConfigV2 = true
            configureStream(codec: config.codec, sets: config.paramSets, width: config.width,
                            height: config.height, fps: config.fps, rotation: config.rotation) {
                decoder.configure(withV2: config, context: $0)
            }
        case .config(let config):
            guard !receivedConfigV2 else { return }
            configureStream(codec: 0, sets: [config.sps, config.pps], width: config.width,
                            height: config.height, fps: config.fps, rotation: config.rotation) {
                decoder.configure(with: config, context: $0)
            }
        case .video(let data, let pts, let isKey):
            liveStats.recordFrame(bytes: data.count, isKeyframe: isKey)
            if statsGate.shouldFire() { stats = liveStats }
            arrivalByPts[pts] = Date()
            arrivalOrder.append(pts)
            if arrivalOrder.count > 120 {
                let stale = arrivalOrder.removeFirst()
                arrivalByPts.removeValue(forKey: stale)
            }
            decoder.decode(annexB: data, ptsUs: pts, isKeyframe: isKey)
        default: break
        }
    }

    private func configureStream(codec: Int, sets: [Data], width: Int, height: Int,
                                 fps: Int, rotation: Int, apply: (StreamFrameContext) -> Void) {
        let desc = StreamConfigDesc.describe(codec: codec, width: width, height: height, fps: fps, rotation: rotation)
        let parameters = sets.map { $0.base64EncodedString() }.joined(separator: ":")
        guard let context = frameContexts.configure(key: desc + ":" + parameters, rotation: rotation) else { return }
        frameQueue.clear()
        keyframeWatchdog.noteConfig(now: now())
        apply(context)
        rotationQuarterTurns = rotation
        codecLabel = codec == WireProtocol.codecHEVC ? "HEVC" : "H.264"
        receivedDescription = "Receiving \(codecLabel) \(width)×\(height) @ \(fps) FPS · \(rotation * 90)°"
        if feedState == .live { statusText = receivedDescription }
    }

    // MARK: - Labels

    var deviceLabel: String {
        if let model = deviceInfo["model"] { return model }
        if let wifiDevice { return wifiDevice.displayName }
        return devices.first?.model ?? "No phone detected"
    }

    var transportLabel: String {
        if case .adb = connection.state.target { return "ADB (development)" }
        if case .address = connection.state.target { return "Network (manual)" }
        switch activeTransport {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case nil: return "—"
        }
    }

    var diagnosticsText: String {
        var text = String(format: "%@ · %.0f FPS · %.1f Mbps",
                          codecLabel, stats.fps, stats.bitrateMbps)
        if stats.processingSampleCount > 0 {
            text += String(format: " · proc p95 %.0f ms", stats.processingP95Ms)
        }
        if activeTransport == .wifi {
            text += " · Wi-Fi low-latency"
        }
        return text
    }

    var menuStatusText: String {
        if connectionState.isConnecting { return "Connecting — \(connectionState.target?.label ?? "phone")" }
        if connected { return "Connected — \(deviceLabel) (\(transportLabel))" }
        if identityMismatch { return "Identity mismatch — see window" }
        if !discoveredDevices.isEmpty {
            return "\(discoveredDevices.count) phone(s) on Wi-Fi — not connected"
        }
        return "Not connected"
    }

    var hasUntrustedDevice: Bool {
        discoveredDevices.contains { !isTrusted($0) }
    }

    private func updateCameraHealth() {
        guard cameraHealthEnabled else { return }
        cameraHealth.update(feedLive: feedState == .live,
            bridgeAvailable: extensionBridge.available,
            extensionEnabled: extensionManager.status == .active && setup.sinkRegistered)
    }

    func checkCameraOutput() {
        if setup.sinkRegistered && !extensionBridge.available { extensionBridge.discoverSink() }
        updateCameraHealth()
        cameraHealth.checkAgain()
    }

    var virtualCameraActive: Bool {
        extensionManager.status == .active && setup.sinkRegistered && extensionBridge.available
    }
    var virtualCameraSendingFrames: Bool {
        guard let lastSent = extensionBridge.lastEnqueuedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - lastSent < 1.0
    }

    var virtualCameraStatusText: String {
        if virtualCameraActive {
            return "Virtual Camera: Active (\(extensionBridge.connectedStreamName ?? "Connected"))"
        }
        return extensionManager.status.description
    }
}

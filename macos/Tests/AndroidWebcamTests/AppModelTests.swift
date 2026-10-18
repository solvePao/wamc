import Foundation
import Network
import CoreVideo
import CoreMedia
import XCTest
import AndroidWebcamCore
import AndroidWebcamProtocol
@testable import AndroidWebcamAppRuntime

@MainActor
final class AppModelTests: XCTestCase {
    func testDisconnectedCommandsAreNoOpsAndLabelsRemainSafe() {
        let model = AppModel(startServices: false)

        XCTAssertFalse(model.canStartCamera)
        XCTAssertEqual(model.deviceLabel, "No phone detected")
        XCTAssertEqual(model.transportLabel, "—")
        XCTAssertTrue(model.diagnosticsText.contains("FPS"))
        model.sendStart()
        model.switchCamera()
        model.rotate()
        XCTAssertFalse(model.facingBack)
        XCTAssertEqual(model.feedState, .idle)
    }

    func testDiagnosticsIncludeProcessingSamplesAndWifiLatencyMode() throws {
        let model = AppModel(startServices: false)
        var stats = StreamStats()
        stats.connectedSince = Date()
        stats.recordFrame(bytes: 256_000, isKeyframe: true)
        stats.recordProcessing(ms: 8)
        model.diagnostics.stats = stats
        let phone = DiscoveredDevice(id: "diagnostic-phone", instanceName: "Pixel",
                                     model: "Pixel", brand: "Google", sdk: 35,
                                     port: 27183, version: 2)
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let connectedModel = AppModel(startServices: false, connection: connection)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 27183)!)
        connection.connect(to: .wifi(phone), endpoint: endpoint, manual: true)
        connectedModel.diagnostics.stats = stats

        XCTAssertTrue(connectedModel.diagnosticsText.contains("proc p95 8 ms"))
        XCTAssertTrue(connectedModel.diagnosticsText.contains("Wi-Fi low-latency"))
        XCTAssertTrue(connectedModel.menuStatusText.hasPrefix("Connecting"))
        XCTAssertEqual(connectedModel.transportLabel, "Wi-Fi")
    }

    func testRefreshDevicesUsesInjectedInventoryAndPreventsOverlappingPolls() async {
        let inventory = FakeDeviceInventory(devices: [
            AndroidDevice(id: "usb-1", model: "Galaxy", state: "device"),
        ], webcams: ["USB Webcam"])
        let model = AppModel(startServices: false, deviceInventory: inventory)
        let refreshed = expectation(description: "inventory results reach the model")
        let fulfillmentLock = NSLock()
        var didFulfill = false
        let observation = model.objectWillChange.sink {
            DispatchQueue.main.async {
                guard !model.devices.isEmpty else { return }
                fulfillmentLock.lock()
                defer { fulfillmentLock.unlock() }
                guard !didFulfill else { return }
                didFulfill = true
                refreshed.fulfill()
            }
        }

        model.refreshDevices()
        model.refreshDevices()
        await fulfillment(of: [refreshed], timeout: 1)
        withExtendedLifetime(observation) {}
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(inventory.androidReads, 1)
        XCTAssertEqual(inventory.webcamReads, 1)
        XCTAssertEqual(model.devices, inventory.devices)
        XCTAssertEqual(model.nativeWebcams, ["USB Webcam"])

        let configured = expectation(description: "selected Android device receives USB setup")
        inventory.onConfigure = { configured.fulfill() }
        model.configureDeviceDefaultUsb()
        await fulfillment(of: [configured], timeout: 1)
        XCTAssertEqual(inventory.configuredSerial, "usb-1")
    }

    func testManualAddressValidationAndSessionSnapshot() {
        let model = AppModel(startServices: false)

        model.manualAddress = "  "
        model.useManualAddress()
        XCTAssertTrue(model.statusText.contains("Enter an address"))

        model.manualAddress = "192.168.1.20:0"
        model.useManualAddress()
        XCTAssertEqual(model.statusText, "Enter a port between 1 and 65535.")

        model.manualAddress = " 192.168.1.20:27183 "
        model.useManualAddress()
        XCTAssertEqual(model.selectedSource, .address("192.168.1.20", 27183))
        XCTAssertEqual(model.sessionAction.sourceLabel, "192.168.1.20:27183 · Wi-Fi")
        XCTAssertEqual(model.sessionAction.action, .start)

        model.manualAddress = "phone.local"
        model.useManualAddress()
        XCTAssertEqual(model.selectedSource, .address("phone.local", 27183))
    }

    func testSelectedAndActiveWifiSourcesStayVisibleAndLabelsTrackTransport() throws {
        let model = AppModel(startServices: false)
        let device = DiscoveredDevice(id: "phone-1", instanceName: "Galaxy", model: "Galaxy",
                                      brand: "Samsung", sdk: 35, port: 27183, version: 2)
        model.discoveredDevices = [device]
        model.selectSource(.wifi(device))

        XCTAssertEqual(model.visibleWifiDevices.map(\.id), ["phone-1"])
        XCTAssertEqual(model.sessionAction.sourceLabel, "Galaxy · phon · Wi-Fi")
        XCTAssertFalse(model.isSourceSelected(.address("192.168.1.20", 27183)))
        XCTAssertFalse(model.isSourceActive(.wifi(device)))

        model.discoveredDevices = []
        XCTAssertEqual(model.visibleWifiDevices.map(\.id), ["phone-1"],
                       "The selected phone remains available if discovery briefly drops it")
    }

    func testWifiConnectionPublishesActiveSessionAndClearsStateOnDisconnect() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection)
        let device = DiscoveredDevice(id: "phone-1", instanceName: "Galaxy", model: "Galaxy",
                                      brand: "Samsung", sdk: 35, port: 27183, version: 2)
        model.selectSource(.wifi(device))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                           port: NWEndpoint.Port(rawValue: 27183)!)
        connection.connect(to: .wifi(device), endpoint: endpoint, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Galaxy", "id": "phone-1"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(model.isSourceActive(.wifi(device)))
        XCTAssertEqual(model.transportLabel, "Wi-Fi")
        XCTAssertEqual(model.menuStatusText, "Connected — Galaxy (Wi-Fi)")
        XCTAssertEqual(model.sessionAction.action, .start)
        model.performSessionAction()
        XCTAssertEqual(model.feedState, .starting)
        XCTAssertEqual(model.sessionAction.action, .stop)

        connection.disconnect()
        XCTAssertFalse(model.isSourceActive(.wifi(device)))
        XCTAssertEqual(model.menuStatusText, "Not connected")
        XCTAssertEqual(model.feedState, .idle)
    }

    func testWifiIdentityMismatchDisconnectsAndSurfacesActionableStatus() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection)
        let expected = DiscoveredDevice(id: "advertised-phone", instanceName: "Galaxy", model: "Galaxy",
                                        brand: "Samsung", sdk: 35, port: 27183, version: 2)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                           port: NWEndpoint.Port(rawValue: 27183)!)

        connection.connect(to: .wifi(expected), endpoint: endpoint, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Other phone", "id": "different-phone"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.identityMismatch)
        XCTAssertEqual(connection.failureMessage, "Wi-Fi phone identity mismatch — disconnected.")
        XCTAssertEqual(model.menuStatusText, "Identity mismatch — see window")
        XCTAssertEqual(model.statusText, "Wi-Fi phone identity mismatch — disconnected.")
    }

    func testQualityModesKeepLabelsAndDimensionsAligned() {
        let model = AppModel(startServices: false)
        XCTAssertEqual(QualityMode.allCases.map(\.rawValue), ["best", "high", "balanced"])
        XCTAssertEqual(QualityMode.best.label, "Best · auto")
        XCTAssertEqual(QualityMode.high.label, "1080p · high")
        XCTAssertEqual(QualityMode.balanced.label, "720p · balanced")
        XCTAssertEqual(QualityMode.best.width, 1920)
        XCTAssertEqual(QualityMode.best.height, 1080)
        XCTAssertEqual(QualityMode.high.width, 1920)
        XCTAssertEqual(QualityMode.high.height, 1080)
        XCTAssertEqual(QualityMode.balanced.width, 1280)
        XCTAssertEqual(QualityMode.balanced.height, 720)
        model.setQuality(.high)
        XCTAssertEqual(model.qualityMode, .high)
        model.setQuality(.high)
        XCTAssertEqual(model.feedState, .idle)
    }

    func testTrustControlsAndDiscoveryMenuStatusStayInSync() {
        let model = AppModel(startServices: false)
        let phone = DiscoveredDevice(id: "coverage-phone-9281", instanceName: "Pixel",
                                     model: "Pixel", brand: "Google", sdk: 35,
                                     port: 27183, version: 2)
        model.discoveredDevices = [phone]
        XCTAssertTrue(model.hasUntrustedDevice)
        XCTAssertEqual(model.menuStatusText, "1 phone(s) on Wi-Fi — not connected")

        model.trustedStore.trust(phone.id)
        XCTAssertTrue(model.isTrusted(phone))
        XCTAssertFalse(model.hasUntrustedDevice)

        model.forgetDevice(phone)
        XCTAssertFalse(model.isTrusted(phone))
        XCTAssertTrue(model.hasUntrustedDevice)
    }

    func testConnectedStreamProcessesStartControlsAndInvalidConfigRecovery() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let decoder = FakeH264Decoder()
        let model = AppModel(startServices: false, connection: connection, decoder: decoder)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        connection.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)

        transport.emit(.hello(["model": "Test phone", "gen": "generation-1"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.deviceLabel, "Test phone")
        XCTAssertEqual(model.transportLabel, "Wi-Fi")

        model.sendStart()
        XCTAssertEqual(model.feedState, .starting)
        XCTAssertEqual(transport.sentControls.last?.first?.1, "start")
        model.switchCamera()
        model.rotate()
        XCTAssertTrue(model.facingBack)
        XCTAssertEqual(transport.sentControls.suffix(2).map { $0.first?.1 }, ["setFacing", "rotate"])

        transport.emit(.hello(["model": "Test phone", "gen": "generation-2"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        let configPayload = WireProtocol.encodeConfig(sps: Data(), pps: Data(), width: 1920,
                                                      height: 1080, fps: 30)
        let config = try XCTUnwrap(WireProtocol.decodeConfig(configPayload))
        transport.emit(.config(config), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.stats.decodeErrors, 1)
        XCTAssertEqual(model.codecLabel, "H.264")

        for pts in 0..<121 {
            transport.emit(.video(Data([0, 0, 1, 0x65]), Int64(pts), pts == 0),
                           attempt: attempt)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(decoder.decodeCount, 121)

        let hevc = WireProtocol.ConfigV2(codec: WireProtocol.codecHEVC, paramSets: [],
                                         width: 1280, height: 720, fps: 30, rotation: 1)
        transport.emit(.configV2(hevc), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.codecLabel, "HEVC")
        XCTAssertEqual(model.rotationQuarterTurns, 1)
        XCTAssertEqual(model.stats.decodeErrors, 2)

        transport.emit(.config(config), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.stats.decodeErrors, 2, "Legacy CONFIG is ignored after CONFIG_V2 negotiation")

        connection.disconnect()
        XCTAssertEqual(model.feedState, .idle)
        XCTAssertFalse(model.canStartCamera)
    }

    func testInjectedDecoderPublishesCurrentFramesAndRequestsRecoveryOnDecodeError() async throws {
        let decoder = FakeH264Decoder()
        let sink = AppModelTestExtensionSink()
        let bridge = ExtensionBridge(sink: sink, now: { 10 })
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection,
                             decoder: decoder, extensionBridge: bridge)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        connection.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone", "gen": "first"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        model.sendStart()
        transport.emit(.hello(["model": "Phone", "gen": "second"]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)

        let config = WireProtocol.ConfigV2(codec: WireProtocol.codecAVC,
                                          paramSets: [Data([0x67]), Data([0x68])],
                                          width: 1920, height: 1080, fps: 30, rotation: 0)
        transport.emit(.configV2(config), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        let context = try XCTUnwrap(decoder.configuredContexts.last)
        decoder.emitFrame(try makePixelBuffer(), ptsUs: 1, context: context)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.feedState, .live)
        XCTAssertEqual(sink.enqueueCount, 1)
        XCTAssertEqual(model.codecLabel, "H.264")

        decoder.emitError(context: context)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.stats.decodeErrors, 1)
        XCTAssertEqual(transport.sentControls.last?.first?.1, "requestKeyframe")

        let nextConfig = WireProtocol.ConfigV2(codec: WireProtocol.codecHEVC,
                                               paramSets: [Data([0x40]), Data([0x42]), Data([0x44])],
                                               width: 1280, height: 720, fps: 30, rotation: 1)
        transport.emit(.configV2(nextConfig), attempt: attempt)
        decoder.emitError(context: context)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.stats.decodeErrors, 1, "A delayed decoder callback from an old config is ignored")
    }

    func testVideoBurstAndQualityChangesKeepOnlyLatestRequestedProfile() async throws {
        let decoder = FakeH264Decoder()
        let sink = AppModelTestExtensionSink()
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection, decoder: decoder,
                             extensionBridge: ExtensionBridge(sink: sink, now: { 10 }))
        model.previewVisible = false
        connection.connect(to: .address("127.0.0.1", 27183), manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        try await waitUntil("HELLO establishes the connection") { model.connected }
        model.sendStart()
        let config = WireProtocol.ConfigV2(codec: WireProtocol.codecAVC,
            paramSets: [Data([0x67]), Data([0x68])], width: 1920, height: 1080, fps: 30, rotation: 0)
        transport.emit(.configV2(config), attempt: attempt)
        transport.emit(.configV2(config), attempt: attempt)
        for pts in 0..<122 {
            transport.emit(.video(Data([0, 0, 1, 0x65]), Int64(pts), pts == 0), attempt: attempt)
        }
        try await waitUntil("All video frames reach the decoder") { decoder.decodeCount == 122 }
        XCTAssertEqual(decoder.configuredContexts.count, 1, "Duplicate configurations must not reset decoding")
        XCTAssertEqual(decoder.decodeCount, 122)
        let context = try XCTUnwrap(decoder.configuredContexts.last)
        decoder.emitFrame(try makePixelBuffer(), ptsUs: 121, context: context)
        try await waitUntil("Decoded frame starts the live feed") { model.feedState == .live }
        XCTAssertEqual(model.feedState, .live)
        XCTAssertEqual(model.stats.decodeErrors, 0)
        XCTAssertFalse(model.virtualCameraSendingFrames,
                      "Injected old frame timestamp must not claim recent delivery")

        model.setQuality(.high)
        model.setQuality(.balanced)
        try await waitUntil("Debounced quality sends the latest profile") {
            model.feedState == .updating && transport.sentControls.filter { $0.first?.1 == "start" }.count == 2
        }
        XCTAssertEqual(model.feedState, .updating)
        let starts = transport.sentControls.filter { $0.first?.1 == "start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try XCTUnwrap(starts.last))["quality"], "balanced")
        transport.emit(.configV2(config), attempt: attempt)
        try await waitUntil("Updated profile configures a new decoder context") { decoder.configuredContexts.count == 2 }
        let updated = try XCTUnwrap(decoder.configuredContexts.last)
        decoder.emitFrame(try makePixelBuffer(), ptsUs: 123, context: updated)
        try await waitUntil("Updated frame restores the live feed") { model.feedState == .live }
        XCTAssertEqual(model.feedState, .live)
        XCTAssertEqual(model.qualityMode, .balanced)
        connection.disconnect()
        decoder.emitFrame(try makePixelBuffer(), ptsUs: 124, context: updated)
        decoder.emitError(context: updated)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.feedState, .idle)
        XCTAssertEqual(model.stats.decodeErrors, 0)
    }

    func testWifiAdvertisementsReachModelAndForgettingConnectedPhoneStopsSession() async throws {
        let transport = FakeStreamTransport()
        let connection = ConnectionController(receiver: transport)
        let model = AppModel(startServices: false, connection: connection)
        let advertisement = WifiAdvertisement(instanceName: "Coverage phone",
            txt: ["id": "coverage-forget-phone", "model": "Phone", "v": "2", "port": "27183"],
            endpoint: .hostPort(host: "127.0.0.1", port: 27183))
        model.wifiDiscovery.apply([advertisement])
        try await Task.sleep(nanoseconds: 20_000_000)
        let phone = try XCTUnwrap(model.discoveredDevices.first)
        XCTAssertEqual(model.wifiStatusText, "Found 1 phone(s) on Wi-Fi")
        XCTAssertEqual(model.wifiDiscovery.endpoint(for: phone), advertisement.endpoint)
        model.trustedStore.trust(phone.id)
        connection.connect(to: .wifi(phone), endpoint: advertisement.endpoint, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone", "id": phone.id]), attempt: attempt)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.connected)
        model.forgetDevice(phone)
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.isTrusted(phone))
        model.wifiDiscovery.apply([])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.discoveredDevices.isEmpty)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 3,
                           condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail(description)
                throw NSError(domain: "AppModelTests.waitUntil", code: 1)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "AppModelTests", code: Int(status))
        }
        return pixelBuffer
    }
}

private final class FakeH264Decoder: H264Decoding {
    var onPixelBuffer: ((CVPixelBuffer, Int64, StreamFrameContext) -> Void)?
    var onError: ((StreamFrameContext) -> Void)?
    private(set) var configuredContexts: [StreamFrameContext] = []
    private(set) var decodeCount = 0

    func configure(with config: WireProtocol.Config, context: StreamFrameContext) {
        configuredContexts.append(context)
        if config.sps.isEmpty || config.pps.isEmpty { onError?(context) }
    }

    func configure(withV2 config: WireProtocol.ConfigV2, context: StreamFrameContext) {
        configuredContexts.append(context)
        if config.paramSets.isEmpty { onError?(context) }
    }

    func decode(annexB: Data, ptsUs: Int64, isKeyframe: Bool) {
        decodeCount += 1
    }
    func invalidate() {}

    func emitFrame(_ pixels: CVPixelBuffer, ptsUs: Int64, context: StreamFrameContext) {
        onPixelBuffer?(pixels, ptsUs, context)
    }

    func emitError(context: StreamFrameContext) { onError?(context) }
}

private final class AppModelTestExtensionSink: ExtensionFrameSink {
    var available = true
    var connectedStreamName: String? = "Android Camera Sink"
    private(set) var enqueueCount = 0
    func discover() {}
    func enqueue(_ sample: CMSampleBuffer) -> ExtensionSinkEnqueueResult {
        enqueueCount += 1
        return .accepted
    }
    func disconnect() { available = false }
}

private final class FakeDeviceInventory: DeviceInventory, @unchecked Sendable {
    let devices: [AndroidDevice]
    let webcams: [String]
    private(set) var androidReads = 0
    private(set) var webcamReads = 0
    private(set) var configuredSerial: String?
    var onConfigure: (() -> Void)?

    init(devices: [AndroidDevice], webcams: [String]) {
        self.devices = devices
        self.webcams = webcams
    }

    func listAndroidDevices() -> [AndroidDevice] {
        androidReads += 1
        return devices
    }

    func nativeUVCWebcams() -> [String] {
        webcamReads += 1
        return webcams
    }

    func configureDefaultUsbMode(serial: String?) -> Bool {
        configuredSerial = serial
        onConfigure?()
        return true
    }
}

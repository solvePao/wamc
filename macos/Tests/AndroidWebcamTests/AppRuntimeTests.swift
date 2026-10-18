import Foundation
import Network
import CoreMedia
import VideoToolbox
import SystemExtensions
import XCTest
import AndroidWebcamCore
@testable import AndroidWebcamProtocol
@testable import AndroidWebcamAppRuntime

final class AppRuntimeTests: XCTestCase {
    func testExtensionRequestStatePreventsDuplicateAndConflictingRequests() {
        var state = CameraExtensionRequestState()

        XCTAssertTrue(state.beginActivation())
        XCTAssertFalse(state.beginActivation())
        XCTAssertFalse(state.beginProperties(currentStatus: .unknown))
        XCTAssertNil(state.finishActivation(.completed))
        XCTAssertTrue(state.beginProperties(currentStatus: .unknown))
        XCTAssertFalse(state.beginProperties(currentStatus: .unknown))
        XCTAssertEqual(state.propertiesFound(installed: true, enabled: true,
                                             awaitingApproval: false), .active)
        XCTAssertTrue(state.beginProperties(currentStatus: .active))
    }

    func testExtensionRequestStateResolvesApprovalFailureAndRestart() {
        var state = CameraExtensionRequestState()

        XCTAssertTrue(state.beginActivation())
        XCTAssertEqual(state.finishActivation(.requiresRestart), .requiresRestart)
        XCTAssertFalse(state.beginProperties(currentStatus: .requiresRestart))

        XCTAssertTrue(state.beginActivation())
        XCTAssertEqual(state.fail(.activation, message: "activation denied"), .failed("activation denied"))
        XCTAssertTrue(state.beginProperties(currentStatus: .failed("activation denied")))
        XCTAssertEqual(state.fail(.properties, message: "properties unavailable"),
                       .failed("properties unavailable"))

        XCTAssertTrue(state.beginActivation())
        XCTAssertEqual(state.finishActivation(.unexpected),
                       .failed("Unexpected installation result. Check Setup & Diagnostics."))
    }

    func testExtensionRequestStateMapsPropertiesIncludingApprovalAndUninstallingResult() {
        var state = CameraExtensionRequestState()

        XCTAssertEqual(state.propertiesFound(installed: false, enabled: false,
                                             awaitingApproval: false), .notInstalled)
        XCTAssertTrue(state.beginProperties(currentStatus: .unknown))
        XCTAssertEqual(state.propertiesFound(installed: true, enabled: false,
                                             awaitingApproval: true), .requiresApproval)
        XCTAssertTrue(state.beginProperties(currentStatus: .requiresApproval))
        XCTAssertEqual(state.propertiesFound(installed: true, enabled: false,
                                             awaitingApproval: false), .disabled)
    }

    @MainActor
    func testCameraExtensionManagerAppliesActivationFailureAndPropertyCallbacks() {
        let manager = CameraExtensionManager()
        manager.status = .activating
        manager.completeActivation(.requiresRestart, refreshAfterCompletion: false)
        XCTAssertEqual(manager.status, .requiresRestart)

        manager.completeActivation(.unexpected, refreshAfterCompletion: false)
        XCTAssertEqual(manager.status, .failed("Unexpected installation result. Check Setup & Diagnostics."))
        manager.failRequest(.properties, message: "property query failed")
        XCTAssertEqual(manager.status, .failed("property query failed"))
        manager.failRequest(.activation, message: "activation denied")
        XCTAssertEqual(manager.status, .failed("activation denied"))

        manager.resolveProperties(installed: false, enabled: false, awaitingApproval: false)
        XCTAssertEqual(manager.status, .notInstalled)
        manager.resolveProperties(installed: true, enabled: false, awaitingApproval: true)
        XCTAssertEqual(manager.status, .requiresApproval)
        manager.resolveProperties(installed: true, enabled: false, awaitingApproval: false)
        XCTAssertEqual(manager.status, .disabled)
        manager.resolveProperties(installed: true, enabled: true, awaitingApproval: false)
        XCTAssertEqual(manager.status, .active)
        manager.completeActivation(.completed, refreshAfterCompletion: false)
        XCTAssertEqual(manager.status, .active, "Completed activation awaits properties refresh")
    }

    @MainActor
    func testExtensionManagerSubmitsOneActivationAndQueriesAfterCompletion() async throws {
        var submitted: [OSSystemExtensionRequest] = []
        var opened: [URL] = []
        let manager = CameraExtensionManager(submitRequest: { submitted.append($0) },
                                             openURL: { opened.append($0) })
        var statuses: [CameraExtensionManager.Status] = []
        let observation = manager.statusPublisher.sink { statuses.append($0) }

        manager.activate()
        manager.activate()
        manager.refreshStatus()
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(manager.status, .activating)
        let activation = try XCTUnwrap(submitted.first)
        XCTAssertTrue(activation.delegate === manager)
        manager.requestNeedsUserApproval(activation)
        await drainMainQueue()
        XCTAssertEqual(manager.status, .requiresApproval)
        manager.request(activation, didFinishWithResult: .completed)
        await drainMainQueue()
        XCTAssertEqual(submitted.count, 2, "Completed activation must refresh installed properties")
        manager.refreshStatus()
        XCTAssertEqual(submitted.count, 2, "Duplicate property queries must be suppressed")
        manager.request(submitted[1], foundProperties: [])
        await drainMainQueue()
        XCTAssertEqual(manager.status, .notInstalled)

        manager.refreshStatus()
        XCTAssertEqual(submitted.count, 3)
        manager.request(submitted[2], didFailWithError: NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Property permission denied"]))
        await drainMainQueue()
        XCTAssertEqual(manager.status, .failed("Property permission denied"))
        manager.refreshStatus()
        XCTAssertEqual(submitted.count, 4, "A failed property query permits retry")
        manager.openSystemSettings()
        XCTAssertEqual(opened.first?.scheme, "x-apple.systempreferences")
        XCTAssertTrue(statuses.contains(.requiresApproval))
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testExtensionManagerHandlesRestartFailureAndDeactivationRequests() async throws {
        var requests: [OSSystemExtensionRequest] = []
        let manager = CameraExtensionManager(submitRequest: { requests.append($0) })
        manager.activate()
        manager.request(try XCTUnwrap(requests.first), didFinishWithResult: .willCompleteAfterReboot)
        await drainMainQueue()
        XCTAssertEqual(manager.status, .requiresRestart)
        manager.refreshStatus()
        XCTAssertEqual(requests.count, 1, "Restart-pending extensions must not be queried again")

        manager.activate()
        manager.request(requests[1], didFailWithError: NSError(domain: "test", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Activation rejected"]))
        await drainMainQueue()
        XCTAssertEqual(manager.status, .failed("Activation rejected"))
        manager.activate()
        XCTAssertEqual(requests.count, 3, "Activation failure permits explicit retry")
        manager.deactivate()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.last?.delegate === manager)
    }

    func testStreamCommandBuildsUsbAndWifiProfilesForEveryQuality() {
        for quality in QualityMode.allCases {
            let usb = Dictionary(uniqueKeysWithValues: StreamCommand.start(quality: quality, transport: .usb))
            let wifi = Dictionary(uniqueKeysWithValues: StreamCommand.start(quality: quality, transport: .wifi))

            XCTAssertEqual(usb["cmd"], "start")
            XCTAssertEqual(usb["quality"], quality.rawValue)
            XCTAssertEqual(usb["width"], String(quality.width))
            XCTAssertEqual(usb["height"], String(quality.height))
            XCTAssertEqual(usb["transport"], "usb")
            XCTAssertNil(usb["latency"])
            XCTAssertEqual(wifi["transport"], "wifi")
            XCTAssertEqual(wifi["latency"], "low")
        }
    }

    func testConnectionTargetAndStateExposeTransportIdentity() {
        let usb = ConnectionTarget.usb(serial: "phone-1")
        let address = ConnectionTarget.address("192.168.1.2", 27183)
        let connecting = ConnectionState.connecting(address)
        let connected = ConnectionState.connected(usb)

        XCTAssertEqual(usb.transport, .usb)
        XCTAssertEqual(usb.key, "usb:phone-1")
        XCTAssertEqual(address.transport, .wifi)
        XCTAssertEqual(address.label, "192.168.1.2:27183")
        XCTAssertEqual(connecting.target, address)
        XCTAssertTrue(connecting.isConnecting)
        XCTAssertFalse(connecting.isConnected)
        XCTAssertEqual(connected.target, usb)
        XCTAssertTrue(connected.isConnected)
        XCTAssertNil(ConnectionState.disconnected.target)
    }

    func testCameraExtensionStatusesHaveActionableDescriptions() {
        let descriptions: [(CameraExtensionManager.Status, String)] = [
            (.unknown, "Virtual camera: Ready to activate"),
            (.notInstalled, "Virtual camera: Not installed"),
            (.activating, "Virtual camera: Installing…"),
            (.requiresApproval, "Virtual camera: Approval required in System Settings"),
            (.disabled, "Virtual camera: Enable Android Camera in System Settings"),
            (.requiresRestart, "Virtual camera: Restart your Mac to finish updating"),
            (.active, "Virtual camera: Active"),
            (.failed("reason"), "Virtual camera error: reason"),
        ]

        for (status, expected) in descriptions {
            XCTAssertEqual(status.description, expected)
        }
    }

    func testCameraExtensionPropertiesResolveInPriorityOrder() {
        XCTAssertEqual(CameraExtensionManager.status(installed: false, enabled: false,
                                                       awaitingApproval: false), .notInstalled)
        XCTAssertEqual(CameraExtensionManager.status(installed: true, enabled: false,
                                                       awaitingApproval: false), .disabled)
        XCTAssertEqual(CameraExtensionManager.status(installed: true, enabled: false,
                                                       awaitingApproval: true), .requiresApproval)
        XCTAssertEqual(CameraExtensionManager.status(installed: true, enabled: true,
                                                       awaitingApproval: true), .active)
        XCTAssertEqual(CameraExtensionManager.status(installed: false, enabled: true,
                                                       awaitingApproval: false), .active)
    }

    func testLoggerCategoriesInitializeWithoutStartingExternalServices() {
        XCTAssertEqual(String(describing: type(of: AppLogger.connection)), "Logger")
        XCTAssertEqual(String(describing: type(of: AppLogger.discovery)), "Logger")
        XCTAssertEqual(String(describing: type(of: AppLogger.setup)), "Logger")
        XCTAssertEqual(String(describing: type(of: AppLogger.stream)), "Logger")
    }

    @MainActor
    func testSessionModelSnapshotsAndCancelsManualConnection() {
        let connection = ConnectionController()
        let model = SessionModel(preferences: isolatedDefaults(), connection: connection)
        let address = ConnectionTarget.address("127.0.0.1", 1)

        let ready = model.snapshot(feed: .idle, sourceLabel: "USB")
        XCTAssertEqual(ready.action, .start)
        XCTAssertEqual(ready.title, "Start stream")

        model.select(address)
        model.start()
        XCTAssertTrue(connection.state.isConnecting)
        let connecting = model.snapshot(feed: .idle, sourceLabel: address.label)
        XCTAssertEqual(connecting.action, .cancel)
        XCTAssertTrue(connecting.isProgress)

        model.stop()
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertFalse(connection.canAutomaticallyConnect(to: address))
    }

    @MainActor
    func testManualConnectionCanBeCancelledWithoutAutomaticRetry() {
        let controller = ConnectionController(receiver: FakeStreamTransport())
        let target = ConnectionTarget.address("127.0.0.1", 1)

        XCTAssertTrue(controller.canAutomaticallyConnect(to: target))
        controller.connect(to: target, manual: true)
        XCTAssertTrue(controller.state.isConnecting)

        controller.disconnect()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(controller.automaticConnectionSuppressed)
        XCTAssertFalse(controller.canAutomaticallyConnect(to: target))
    }

    @MainActor
    func testConnectionControllerNegotiatesAndIgnoresStaleEvents() async throws {
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        var hellos: [Bool] = []
        var streamEvents = 0
        let firstHello = expectation(description: "first HELLO is accepted")
        controller.onHello = { _, first in
            hellos.append(first)
            if first { firstHello.fulfill() }
        }
        let repeatHello = expectation(description: "repeat HELLO is accepted")
        let firstStreamEvent = expectation(description: "stream event is forwarded")
        controller.onStreamEvent = { _ in
            streamEvents += 1
            firstStreamEvent.fulfill()
        }

        controller.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        XCTAssertEqual(controller.state, .connecting(target))

        transport.emit(.transportReady, attempt: attempt)
        transport.emit(.hello(["model": "Phone", "id": "phone-1"]), attempt: attempt)
        await fulfillment(of: [firstHello], timeout: 1)
        XCTAssertEqual(transport.sentControls.last?.map(\.0), ["cmd", "codecs", "configV2"])
        XCTAssertEqual(controller.state, .connected(target))
        XCTAssertEqual(hellos, [true])
        controller.onHello = { _, first in
            hellos.append(first)
            repeatHello.fulfill()
        }
        transport.emit(.hello(["model": "Phone", "id": "phone-1"]), attempt: attempt)
        await fulfillment(of: [repeatHello], timeout: 1)
        XCTAssertEqual(hellos, [true, false])
        transport.emit(.video(Data([1]), 5, true), attempt: attempt)
        await fulfillment(of: [firstStreamEvent], timeout: 1)
        XCTAssertEqual(streamEvents, 1)

        controller.disconnect()
        XCTAssertEqual(controller.state, .disconnected)
        transport.emit(.transportLost, attempt: attempt)
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testConnectionControllerRejectsWifiMismatchAndMissingEndpoint() async throws {
        let device = DiscoveredDevice(id: "trusted-id", instanceName: "Phone", model: "Phone",
                                      brand: "", sdk: nil, port: 27183, version: 2)
        let wifi = ConnectionTarget.wifi(device)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 27183)!)

        let mismatchTransport = FakeStreamTransport()
        let mismatch = ConnectionController(receiver: mismatchTransport)
        mismatch.connect(to: wifi, endpoint: endpoint, manual: true)
        let attempt = try XCTUnwrap(mismatchTransport.attempt)
        let disconnected = expectation(description: "identity mismatch disconnects")
        mismatch.onStateChange = { state, _ in
            if state == .disconnected { disconnected.fulfill() }
        }
        mismatchTransport.emit(.hello(["model": "Phone", "id": "other-id"]), attempt: attempt)
        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertTrue(mismatch.identityMismatch)
        XCTAssertEqual(mismatch.state, .disconnected)
        XCTAssertTrue(mismatch.failureMessage?.contains("identity mismatch") == true)

        let unavailableTransport = FakeStreamTransport()
        let unavailable = ConnectionController(receiver: unavailableTransport)
        unavailable.connect(to: wifi, endpoint: nil, manual: true)
        XCTAssertEqual(unavailable.state, .disconnected)
        XCTAssertEqual(unavailable.failureMessage, "That phone is no longer reachable on Wi-Fi.")
        XCTAssertNil(unavailableTransport.attempt)
    }

    @MainActor
    func testConnectionControllerRejectsZeroPortAndBlocksAutomaticRetry() {
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport)
        let invalid = ConnectionTarget.address("127.0.0.1", 0)

        controller.connect(to: invalid, manual: false)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.failureMessage, "Invalid phone port.")
        XCTAssertFalse(controller.canAutomaticallyConnect(to: invalid))
        XCTAssertNil(transport.attempt)
    }

    @MainActor
    func testConnectionControllerRetriesAfterTransportLossAndStopsCameraBeforeDisconnect() async throws {
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport)
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        controller.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        let connected = expectation(description: "first HELLO establishes connection")
        controller.onStateChange = { state, _ in
            if state == .connected(target) { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 1)

        transport.emit(.transportLost, attempt: attempt)
        let reconnecting = expectation(description: "transport loss arms reconnect state")
        DispatchQueue.main.async {
            if controller.state == .connecting(target) { reconnecting.fulfill() }
        }
        await fulfillment(of: [reconnecting], timeout: 1)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        let reconnected = expectation(description: "new HELLO returns to connected")
        controller.onStateChange = { state, _ in
            if state == .connected(target) { reconnected.fulfill() }
        }
        await fulfillment(of: [reconnected], timeout: 1)

        let finished = expectation(description: "stop completion finishes disconnect")
        controller.disconnect(stopCamera: true) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(transport.sentControls.last?.first?.1, "stop")
        XCTAssertEqual(controller.state, .disconnected)

        var immediateCompletionRan = false
        controller.disconnect { immediateCompletionRan = true }
        XCTAssertTrue(immediateCompletionRan)
    }

    @MainActor
    func testConnectionTimeoutBlocksAutomaticRetryUntilTargetDisappears() async throws {
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport, connectionTimeout: .milliseconds(1))
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        let timedOut = expectation(description: "Missing HELLO fails the connection deadline")
        controller.onStateChange = { state, _ in
            if state == .disconnected { timedOut.fulfill() }
        }
        controller.connect(to: target, manual: false)
        controller.connect(to: target, manual: false)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": ""]), attempt: attempt)
        transport.emit(.hello([:]), attempt: attempt)
        transport.emit(.video(Data([1]), 1, false), attempt: attempt)
        transport.emit(.transportLost, attempt: attempt)
        controller.usbWasRemoved()
        await fulfillment(of: [timedOut], timeout: 6)

        XCTAssertTrue(controller.failureMessage?.contains("within 5 seconds") == true)
        XCTAssertFalse(controller.canAutomaticallyConnect(to: target))
        controller.clearFailure()
        XCTAssertNil(controller.failureMessage)
        controller.updateAvailableTargets([target])
        XCTAssertFalse(controller.canAutomaticallyConnect(to: target))
        controller.updateAvailableTargets([])
        XCTAssertTrue(controller.canAutomaticallyConnect(to: target))
        controller.sendControl([("cmd", "start")])
        XCTAssertTrue(transport.sentControls.isEmpty)
    }

    @MainActor
    func testStopTimeoutCompletesAllWaitersAndRejectsNewConnectionsDuringTeardown() async throws {
        let transport = FakeStreamTransport()
        let controller = ConnectionController(receiver: transport, stopTimeout: .milliseconds(1))
        let target = ConnectionTarget.address("127.0.0.1", 27183)
        controller.connect(to: target, manual: true)
        let attempt = try XCTUnwrap(transport.attempt)
        transport.emit(.hello(["model": "Phone"]), attempt: attempt)
        await drainMainQueue()
        XCTAssertTrue(controller.state.isConnected)
        transport.completesControls = false
        let first = expectation(description: "First stop waiter finishes despite missing acknowledgement")
        let second = expectation(description: "Repeated stop waiter also finishes")
        controller.disconnect(stopCamera: true) { first.fulfill() }
        controller.disconnect(stopCamera: true) { second.fulfill() }
        controller.connect(to: .address("other", 27183), manual: true)
        transport.emit(.hello(["model": "Late phone"]), attempt: attempt)
        await fulfillment(of: [first, second], timeout: 2)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(transport.sentControls.filter { $0.first?.1 == "stop" }.count, 1)
        transport.pendingCompletions.forEach { $0() }
        await drainMainQueue()
        XCTAssertEqual(controller.state, .disconnected, "Late acknowledgement must not run completions twice")
    }

    func testStreamReceiverDescribesHostAndBonjourEndpoints() {
        let host = NWEndpoint.hostPort(host: "192.168.1.2", port: 27183)
        let service = NWEndpoint.service(name: "WAMC Phone", type: "_wamc._tcp", domain: "local", interface: nil)

        XCTAssertEqual(StreamReceiver.describe(host), "192.168.1.2:27183")
        XCTAssertEqual(StreamReceiver.describe(service), "WAMC Phone")
    }

    func testDecoderReportsInvalidLegacyAndNegotiatedConfigurations() throws {
        let decoder = H264Decoder()
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "test", rotation: 0))
        var failedContexts: [StreamFrameContext] = []
        decoder.onError = { failedContexts.append($0) }

        decoder.configure(
            with: WireProtocol.Config(sps: Data(), pps: Data(), width: 1920, height: 1080, fps: 30),
            context: context)
        decoder.configure(
            withV2: WireProtocol.ConfigV2(codec: WireProtocol.codecHEVC, paramSets: [Data()],
                                          width: 1920, height: 1080, fps: 30),
            context: context)
        decoder.decode(annexB: Data([0, 0, 1, 0x65]), ptsUs: 0, isKeyframe: true)

        XCTAssertEqual(failedContexts, [context, context])
    }

    func testDecoderStripsThreeAndFourByteParameterSetStartCodes() throws {
        let decoder = H264Decoder()
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "start-codes", rotation: 0))
        var failedContexts: [StreamFrameContext] = []
        decoder.onError = { failedContexts.append($0) }

        decoder.configure(
            with: WireProtocol.Config(sps: Data([0, 0, 0, 1]), pps: Data([0, 0, 1]),
                                      width: 1920, height: 1080, fps: 30),
            context: context)

        XCTAssertEqual(failedContexts, [context])
    }

    func testDecoderReportsMalformedNonemptyParameterSets() throws {
        let decoder = H264Decoder()
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "malformed", rotation: 0))
        var failedContexts: [StreamFrameContext] = []
        decoder.onError = { failedContexts.append($0) }

        decoder.configure(
            with: WireProtocol.Config(sps: Data([0x67, 0x00]), pps: Data([0x68, 0x00]),
                                      width: 1920, height: 1080, fps: 30), context: context)
        decoder.configure(
            withV2: WireProtocol.ConfigV2(codec: WireProtocol.codecHEVC,
                                          paramSets: [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])],
                                          width: 1920, height: 1080, fps: 30), context: context)
        decoder.configure(
            withV2: WireProtocol.ConfigV2(codec: WireProtocol.codecAVC,
                                          paramSets: [Data([0x67, 0x00]), Data([0x68, 0x00])],
                                          width: 1920, height: 1080, fps: 30), context: context)

        XCTAssertEqual(failedContexts, [context, context, context])
    }

    func testDecoderReportsVideoToolboxSessionCreationFailure() throws {
        var attemptedSessionCreation = false
        let decoder = H264Decoder(sessionFactory: { _, _, _ in
            attemptedSessionCreation = true
            return (status: -12909, session: nil)
        }, formatFactory: { _, _, width, height in
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                width: Int32(width), height: Int32(height), extensions: nil,
                formatDescriptionOut: &format)
            return (status, format)
        })
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "session-failure", rotation: 0))
        var failedContexts: [StreamFrameContext] = []
        decoder.onError = { failedContexts.append($0) }
        let sps = Data([0x67, 0x42, 0x00, 0x1e, 0x95, 0xa8, 0x14, 0x01,
                        0x6e, 0x9b, 0x80, 0x80, 0x80, 0xa0])
        let pps = Data([0x68, 0xce, 0x3c, 0x80])

        decoder.configure(with: WireProtocol.Config(sps: sps, pps: pps,
                                                       width: 1280, height: 720, fps: 30),
                          context: context)

        XCTAssertTrue(attemptedSessionCreation)
        XCTAssertEqual(failedContexts, [context])
    }

    func testDecoderPassesStrippedHEVCParameterSetsToFormatFactory() throws {
        var received: (Int, [Data], Int, Int)?
        let decoder = H264Decoder(sessionFactory: { _, _, _ in
            (status: -12909, session: nil)
        }, formatFactory: { codec, sets, width, height in
            received = (codec, sets, width, height)
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                width: Int32(width), height: Int32(height), extensions: nil,
                formatDescriptionOut: &format)
            return (status, format)
        })
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "hevc-format", rotation: 90))
        var failedContexts: [StreamFrameContext] = []
        decoder.onError = { failedContexts.append($0) }
        let parameterSets = [
            Data([0, 0, 1, 0x40, 0x01]),
            Data([0, 0, 0, 1, 0x42, 0x01]),
            Data([0x44, 0x01]),
        ]

        decoder.configure(withV2: WireProtocol.ConfigV2(
            codec: WireProtocol.codecHEVC, paramSets: parameterSets,
            width: 1280, height: 720, fps: 30), context: context)

        XCTAssertEqual(received?.0, WireProtocol.codecHEVC)
        XCTAssertEqual(received?.1, [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])])
        XCTAssertEqual(received?.2, 1280)
        XCTAssertEqual(received?.3, 720)
        XCTAssertEqual(failedContexts, [context])
    }

    func testDecoderSessionLifecycleAndKeyframeRecoveryThroughAdapter() throws {
        let decoderSession = FakeVideoToolboxDecodingSession(statuses: [noErr, -12909])
        var outputCallback: VTDecompressionOutputCallback?
        var outputRefCon: UnsafeMutableRawPointer?
        let decoder = H264Decoder(sessionFactory: { _, callback, _ in
            outputCallback = callback.decompressionOutputCallback
            outputRefCon = callback.decompressionOutputRefCon
            return (status: noErr, session: decoderSession)
        },
                                  formatFactory: { _, _, width, height in
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                width: Int32(width), height: Int32(height), extensions: nil,
                formatDescriptionOut: &format)
            return (status, format)
        })
        let tracker = StreamFrameContextTracker()
        let context = try XCTUnwrap(tracker.configure(key: "decoder-adapter", rotation: 0))
        var errors: [StreamFrameContext] = []
        decoder.onError = { errors.append($0) }
        decoder.configure(with: WireProtocol.Config(sps: Data([0x67]), pps: Data([0x68]),
                                                    width: 16, height: 16, fps: 30), context: context)

        XCTAssertEqual(decoderSession.configureCount, 1)
        decoder.decode(annexB: Data([0, 0, 1, 0x41]), ptsUs: 1, isKeyframe: false)
        XCTAssertEqual(decoderSession.decodeCount, 0, "Inter frames are ignored until the first keyframe")
        decoder.decode(annexB: Data([0, 0, 1, 0x65]), ptsUs: 2, isKeyframe: true)
        XCTAssertEqual(decoderSession.decodeCount, 1)
        decoder.decode(annexB: Data([0, 0, 1, 0x41]), ptsUs: 3, isKeyframe: false)

        XCTAssertEqual(decoderSession.decodeCount, 2)
        XCTAssertEqual(errors, [context], "A VideoToolbox submission error requests recovery")
        let callback = try XCTUnwrap(outputCallback)
        let pixels = try makePixelBuffer()
        var deliveredContext: StreamFrameContext?
        var deliveredPts: Int64?
        decoder.onPixelBuffer = { _, pts, frameContext in
            deliveredPts = pts
            deliveredContext = frameContext
        }
        callback(outputRefCon, nil, noErr, VTDecodeInfoFlags(rawValue: 0), pixels,
                 CMTime(value: 45_000, timescale: 1_000_000), .invalid)
        XCTAssertEqual(deliveredContext, context)
        XCTAssertEqual(deliveredPts, 45_000)

        callback(outputRefCon, nil, -12909, VTDecodeInfoFlags(rawValue: 0), nil, .invalid, .invalid)
        XCTAssertEqual(errors, [context, context], "Failed output callbacks preserve stream identity")
        decoder.invalidate()
        XCTAssertEqual(decoderSession.invalidateCount, 1)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                         &pixelBuffer)
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "AppRuntimeTests", code: Int(result))
        }
        return pixelBuffer
    }
}

private final class FakeVideoToolboxDecodingSession: VideoToolboxDecodingSession {
    private var statuses: [OSStatus]
    private(set) var configureCount = 0
    private(set) var decodeCount = 0
    private(set) var invalidateCount = 0

    init(statuses: [OSStatus]) { self.statuses = statuses }
    func configureRealtime() { configureCount += 1 }
    func decode(_ sampleBuffer: CMSampleBuffer) -> OSStatus {
        decodeCount += 1
        return statuses.removeFirst()
    }
    func invalidate() { invalidateCount += 1 }
}

final class FakeStreamTransport: StreamTransport {
    var onEvent: ((UUID, StreamReceiver.Event) -> Void)?
    private(set) var attempt: UUID?
    private(set) var sentControls: [[(String, String)]] = []
    var completesControls = true
    var pendingCompletions: [() -> Void] = []

    func start(endpoint: NWEndpoint, attempt: UUID) { self.attempt = attempt }
    func stop() { attempt = nil }
    func sendControl(_ fields: [(String, String)], attempt: UUID, completion: (() -> Void)?) {
        sentControls.append(fields)
        if completesControls { completion?() }
        else if let completion { pendingCompletions.append(completion) }
    }
    func emit(_ event: StreamReceiver.Event, attempt: UUID) { onEvent?(attempt, event) }
}

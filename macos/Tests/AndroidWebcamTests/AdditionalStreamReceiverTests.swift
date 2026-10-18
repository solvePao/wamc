import XCTest
import Network
@testable import AndroidWebcamAppRuntime
@testable import AndroidWebcamProtocol

final class AdditionalStreamReceiverTests: XCTestCase {
    func testNetworkAdapterRetainsAndClearsStateHandler() {
        let connection = NetworkStreamConnection(endpoint: .hostPort(host: "localhost", port: 1234))
        XCTAssertNil(connection.stateUpdateHandler)
        connection.stateUpdateHandler = { _ in }
        XCTAssertNotNil(connection.stateUpdateHandler)
        connection.stateUpdateHandler = nil
        XCTAssertNil(connection.stateUpdateHandler)
        connection.cancel()
    }

    func testSystemConnectionSendsControlToLoopbackPeer() async throws {
        let queue = DispatchQueue(label: "wamc.control-loopback")
        let listener = try NWListener(using: .tcp, on: .any)
        let receiver = StreamReceiver()
        let attempt = UUID()
        let received = expectation(description: "peer receives framed control")
        let completed = expectation(description: "network send completes")
        let peer = LoopbackPeer()
        receiver.onEvent = { [weak receiver] eventAttempt, event in
            guard eventAttempt == attempt, case .transportReady = event else { return }
            receiver?.sendControl([("cmd", "start")], attempt: attempt) { completed.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            peer.connection = connection
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: WireProtocol.headerSize + Data("cmd=start".utf8).count,
                                   maximumLength: 1024) { data, _, _, error in
                    XCTAssertNil(error)
                    let frames = FrameParser().feed(data ?? Data())
                    XCTAssertEqual(frames.count, 1)
                    XCTAssertEqual(frames.first.map { WireProtocol.decodeControl($0.payload) }, ["cmd": "start"])
                    received.fulfill()
                }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            receiver.start(endpoint: .hostPort(host: .ipv4(.loopback), port: port), attempt: attempt)
        }
        listener.start(queue: queue)
        defer {
            receiver.stop()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            queue.sync {
                peer.connection?.stateUpdateHandler = nil
                peer.connection?.cancel()
                peer.connection = nil
            }
        }
        await fulfillment(of: [received, completed], timeout: 5)
    }

    func testControlsReportCompletionAfterTransportError() {
        let fixture = ReceiverFixture()
        defer { fixture.stop() }
        fixture.start()
        fixture.queue.sync { fixture.connections[0].sendError = .posix(.EPIPE) }
        var completions = 0
        fixture.receiver.sendControl([("cmd", "start")], attempt: fixture.attempt) { completions += 1 }
        fixture.queue.sync {
            XCTAssertEqual(completions, 1)
            let frames = FrameParser().feed(fixture.connections[0].sent[0])
            XCTAssertEqual(frames.first?.type, 3)
            XCTAssertEqual(WireProtocol.decodeControl(frames[0].payload), ["cmd": "start"])
        }
    }

    func testNegotiatedFramesContinueReceivingUntilErrorCancelsTransport() {
        let fixture = ReceiverFixture()
        defer { fixture.stop() }
        let config = WireProtocol.ConfigV2(codec: 1, paramSets: [Data([1]), Data([2]), Data([3])],
                                           width: 1920, height: 1080, fps: 30, rotation: 1)
        var configs: [WireProtocol.ConfigV2] = []
        let expectedAttempt = fixture.attempt
        fixture.receiver.onEvent = { attempt, event in
            XCTAssertEqual(attempt, expectedAttempt)
            if case .configV2(let value) = event { configs.append(value) }
        }
        fixture.start()
        fixture.queue.sync {
            let connection = fixture.connections[0]
            let bytes = WireProtocol.encode(type: 5, flags: 0, ptsUs: 0,
                payload: WireProtocol.encodeConfigV2(codec: config.codec, paramSets: config.paramSets,
                    width: config.width, height: config.height, fps: config.fps, rotation: config.rotation))
            connection.deliver(bytes.prefix(7))
            connection.deliver(bytes.dropFirst(7))
            XCTAssertEqual(configs, [config])
            XCTAssertEqual(connection.receiveCalls, 3)
            connection.deliver(nil, error: .posix(.ECONNRESET))
            XCTAssertEqual(connection.cancellations, 1)
        }
    }

    func testFailedAndCancelledConnectionsReconnectWithoutFixedWaits() {
        let fixture = ReceiverFixture()
        defer { fixture.stop() }
        var losses = 0
        fixture.receiver.onEvent = { _, event in if case .transportLost = event { losses += 1 } }
        fixture.start()
        fixture.queue.sync {
            fixture.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
            XCTAssertEqual(losses, 1)
            XCTAssertEqual(fixture.reconnectDelays, [0.5])
            fixture.scheduled.removeFirst()()
            XCTAssertEqual(fixture.connections.count, 2)
            fixture.connections[1].stateUpdateHandler?(.cancelled)
            XCTAssertEqual(losses, 2)
            // A ready connection resets the backoff before another drop.
            XCTAssertEqual(fixture.reconnectDelays, [0.5, 0.5])
        }
        fixture.stop()
        fixture.queue.sync {
            fixture.scheduled.removeFirst()()
            XCTAssertEqual(fixture.connections.count, 2, "A deferred reconnect cannot restart a stopped receiver")
        }
    }

    func testOldCallbacksCannotReviveReplacedConnection() {
        let fixture = ReceiverFixture()
        defer { fixture.stop() }
        fixture.start()
        var staleState: ((NWConnection.State) -> Void)?
        var staleReceive: ((Data?, Bool, NWError?) -> Void)?
        fixture.queue.sync {
            staleState = fixture.connections[0].stateUpdateHandler
            staleReceive = fixture.connections[0].pendingReceive
        }
        fixture.receiver.start(endpoint: .hostPort(host: "localhost", port: 1234), attempt: UUID())
        fixture.queue.sync {
            staleState?(.ready)
            staleReceive?(Data([1]), false, nil)
            XCTAssertEqual(fixture.connections.count, 2)
            XCTAssertEqual(fixture.connections[0].receiveCalls, 1)
            XCTAssertEqual(fixture.connections[1].receiveCalls, 1)
        }
    }

    func testUrlEndpointDescriptionRetainsAddress() {
        let endpoint = NWEndpoint.url(URL(string: "https://example.com/stream")!)
        XCTAssertEqual(StreamReceiver.describe(endpoint), String(describing: endpoint))
    }
}

private final class LoopbackPeer {
    // Accessed only on the listener's serial queue.
    var connection: NWConnection?
}

private final class ReceiverFixture {
    let queue = DispatchQueue(label: "wamc.receiver-fixture")
    let attempt = UUID()
    var connections: [StubStreamConnection] = []
    var reconnectDelays: [TimeInterval] = []
    var scheduled: [() -> Void] = []
    lazy var receiver = StreamReceiver(queue: queue, makeConnection: { [unowned self] _ in
        let connection = StubStreamConnection()
        connections.append(connection)
        return connection
    }, scheduleReconnect: { [unowned self] delay, action in
        reconnectDelays.append(delay)
        scheduled.append(action)
    })
    func start() {
        receiver.start(endpoint: .hostPort(host: "localhost", port: 1234), attempt: attempt)
        queue.sync {}
    }
    func stop() {
        receiver.stop()
        queue.sync {}
    }
}

private final class StubStreamConnection: StreamConnection {
    var stateUpdateHandler: ((NWConnection.State) -> Void)?
    var pendingReceive: ((Data?, Bool, NWError?) -> Void)?
    var sendError: NWError?
    var sent: [Data] = []
    var receiveCalls = 0
    var cancellations = 0
    func start(queue: DispatchQueue) {
        stateUpdateHandler?(.preparing)
        stateUpdateHandler?(.ready)
    }
    func cancel() { cancellations += 1; pendingReceive = nil }
    func send(content: Data, completion: @escaping (NWError?) -> Void) {
        sent.append(content)
        completion(sendError)
    }
    func receive(completion: @escaping (Data?, Bool, NWError?) -> Void) {
        receiveCalls += 1
        pendingReceive = completion
    }
    func deliver(_ bytes: Data?, error: NWError? = nil) {
        let callback = pendingReceive
        pendingReceive = nil
        callback?(bytes, false, error)
    }
}

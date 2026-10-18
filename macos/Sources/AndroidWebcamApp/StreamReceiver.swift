import Foundation
import Network
import AndroidWebcamCore
import AndroidWebcamProtocol
import OSLog

protocol StreamTransport: AnyObject {
    var onEvent: ((UUID, StreamReceiver.Event) -> Void)? { get set }
    func start(endpoint: NWEndpoint, attempt: UUID)
    func stop()
    func sendControl(_ fields: [(String, String)], attempt: UUID, completion: (() -> Void)?)
}

protocol StreamConnection: AnyObject {
    var stateUpdateHandler: ((NWConnection.State) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
    func send(content: Data, completion: @escaping (NWError?) -> Void)
    func receive(completion: @escaping (Data?, Bool, NWError?) -> Void)
}

final class NetworkStreamConnection: StreamConnection {
    private let connection: NWConnection
    var stateUpdateHandler: ((NWConnection.State) -> Void)? {
        get { connection.stateUpdateHandler }
        set { connection.stateUpdateHandler = newValue }
    }
    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }
    func start(queue: DispatchQueue) { connection.start(queue: queue) }
    func cancel() { connection.cancel() }
    func send(content: Data, completion: @escaping (NWError?) -> Void) {
        connection.send(content: content, completion: .contentProcessed(completion))
    }
    func receive(completion: @escaping (Data?, Bool, NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            data, _, complete, error in completion(data, complete, error)
        }
    }
}

/// One serial parser and control channel for USB and Wi-Fi. Every callback
/// carries the attempt that produced it; cancellation cannot revive an old dial.
final class StreamReceiver: StreamTransport {
    enum Event {
        case transportReady
        case transportLost
        case video(Data, Int64, Bool)
        case config(WireProtocol.Config)
        case configV2(WireProtocol.ConfigV2)
        case hello([String: String])
    }

    var onEvent: ((UUID, Event) -> Void)?
    private let queue: DispatchQueue
    private let makeConnection: (NWEndpoint) -> StreamConnection
    private let scheduleReconnect: (TimeInterval, @escaping () -> Void) -> Void
    private var connection: StreamConnection?
    private var attempt: UUID?
    private var endpoint: NWEndpoint?
    private var parser = FrameParser()
    private var reconnect = ReconnectPolicy()

    init(queue: DispatchQueue = DispatchQueue(label: "awc.receiver"),
         makeConnection: @escaping (NWEndpoint) -> StreamConnection = { NetworkStreamConnection(endpoint: $0) },
         scheduleReconnect: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.queue = queue
        self.makeConnection = makeConnection
        self.scheduleReconnect = scheduleReconnect ?? { delay, action in
            queue.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    func start(endpoint: NWEndpoint, attempt: UUID) {
        queue.async { [self] in
            stopOnQueue()
            self.attempt = attempt
            self.endpoint = endpoint
            reconnect.reset()
            connect(attempt: attempt)
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    func sendControl(_ fields: [(String, String)], attempt: UUID,
                     completion: (() -> Void)? = nil) {
        let frame = WireProtocol.encode(type: 3, flags: 0, ptsUs: 0,
                                        payload: WireProtocol.encodeControl(fields))
        queue.async { [self] in
            guard self.attempt == attempt, let connection else {
                completion?()
                return
            }
            connection.send(content: frame, completion: { error in
                if let error {
                    AppLogger.connection.error("Sending stream control frame failed: \(error.localizedDescription, privacy: .private)")
                }
                completion?()
            })
        }
    }

    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port.rawValue)"
        case .service(let name, _, _, _): return name
        default: return "\(endpoint)"
        }
    }

    private func stopOnQueue() {
        attempt = nil
        endpoint = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = FrameParser()
    }

    private func connect(attempt: UUID) {
        guard self.attempt == attempt, let endpoint else { return }
        parser = FrameParser()
        let conn = makeConnection(endpoint)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.attempt == attempt, self.connection === conn else { return }
            switch state {
            case .ready:
                self.reconnect.reset()
                self.onEvent?(attempt, .transportReady)
                self.receiveLoop(conn, attempt: attempt)
            case .failed(let error):
                AppLogger.connection.error("Network connection to \(Self.describe(endpoint), privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
                self.reconnect(attempt: attempt, connection: conn)
            case .cancelled:
                self.reconnect(attempt: attempt, connection: conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func reconnect(attempt: UUID, connection conn: StreamConnection) {
        guard self.attempt == attempt, self.connection === conn else { return }
        self.connection = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        self.onEvent?(attempt, .transportLost)
        let delay = self.reconnect.nextDelay()
        scheduleReconnect(delay) { [weak self] in
            self?.connect(attempt: attempt)
        }
    }

    private func receiveLoop(_ conn: StreamConnection, attempt: UUID) {
        conn.receive {
            [weak self] data, isComplete, error in
            guard let self, self.attempt == attempt, self.connection === conn else { return }
            if let data, !data.isEmpty {
                for frame in self.parser.feed(data) {
                    let event: Event?
                    switch frame.type {
                    case 1: event = .video(frame.payload, frame.ptsUs, frame.isKeyframe)
                    case 2: event = WireProtocol.decodeConfig(frame.payload).map(Event.config)
                    case 5: event = WireProtocol.decodeConfigV2(frame.payload).map(Event.configV2)
                    case 4: event = .hello(WireProtocol.decodeControl(frame.payload))
                    default: event = nil
                    }
                    if let event { self.onEvent?(attempt, event) }
                }
            }
            if let error {
                AppLogger.connection.error("Receiving stream data failed: \(error.localizedDescription, privacy: .private)")
                conn.cancel()
            } else if isComplete {
                conn.cancel()
            } else {
                self.receiveLoop(conn, attempt: attempt)
            }
        }
    }
}

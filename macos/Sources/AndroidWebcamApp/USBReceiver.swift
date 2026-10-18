import Foundation
import Network
import AndroidWebcamCore
import AndroidWebcamProtocol

/// TCP receiver for the ADB-forwarded stream, with auto-reconnect.
/// AOA bulk transport on macOS arrives on the same socket path once the
/// host-side accessory negotiation presents the stream (docs/ACCESSORY.md).
final class USBReceiver {
    var onVideo: ((Data, Int64, Bool) -> Void)?
    var onConfig: ((WireProtocol.Config) -> Void)?
    var onConfigV2: ((WireProtocol.ConfigV2) -> Void)?
    var onHello: (([String: String]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var connection: NWConnection?
    private var parser = FrameParser()
    private var reconnect = ReconnectPolicy()
    private var stopped = true
    private let queue = DispatchQueue(label: "awc.receiver")
    private let port: UInt16

    init(port: UInt16 = 27183) { self.port = port }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
    }

    func sendControl(_ fields: [(String, String)]) {
        let frame = WireProtocol.encode(type: 3, flags: 0, ptsUs: 0,
                                        payload: WireProtocol.encodeControl(fields))
        connection?.send(content: frame, completion: .idempotent)
    }

    private func connect() {
        guard !stopped else { return }
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reconnect.reset()
                self.onConnectionChange?(true)
                self.receiveLoop(conn)
            case .failed, .cancelled:
                self.onConnectionChange?(false)
                self.scheduleReconnect()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = reconnect.nextDelay()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in self.parser.feed(data) { self.dispatch(frame) }
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func dispatch(_ frame: WireProtocol.Frame) {
        switch frame.type {
        case 1: onVideo?(frame.payload, frame.ptsUs, frame.isKeyframe)
        case 2: WireProtocol.decodeConfig(frame.payload).map { onConfig?($0) }
        case 5: WireProtocol.decodeConfigV2(frame.payload).map { onConfigV2?($0) }
        case 4: onHello?(WireProtocol.decodeControl(frame.payload))
        default: break
        }
    }
}

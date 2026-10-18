import Foundation
import Network
import XCTest
import AndroidWebcamProtocol
@testable import AndroidWebcamAppRuntime

final class StreamReceiverIntegrationTests: XCTestCase {
    func testReceiverParsesFramesOverLoopbackTcp() async throws {
        let queue = DispatchQueue(label: "wamc.receiver-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let receiver = StreamReceiver()
        let attempt = UUID()
        let transportReady = expectation(description: "transport is ready")
        let helloReceived = expectation(description: "HELLO frame is parsed")
        let configReceived = expectation(description: "CONFIG frame is parsed")
        let videoReceived = expectation(description: "video frame is parsed")
        let sendComplete = expectation(description: "server sends frames")
        let transportLost = expectation(description: "closed peer is reported and scheduled for reconnect")
        let payload = Data([0, 0, 1, 0x65])
        var didSend = false

        receiver.onEvent = { receivedAttempt, event in
            guard receivedAttempt == attempt else { return }
            switch event {
            case .transportReady: transportReady.fulfill()
            case .transportLost: transportLost.fulfill()
            case .hello(let fields):
                if fields["model"] == "Loopback phone" { helloReceived.fulfill() }
            case .config(let config):
                if config.width == 1920 && config.height == 1080 { configReceived.fulfill() }
            case .video(let data, let pts, let keyframe):
                if data == payload && pts == 42 && keyframe { videoReceived.fulfill() }
            default: break
            }
        }

        let frames = [
            WireProtocol.encode(type: 4, flags: 0, ptsUs: 0,
                                payload: WireProtocol.encodeControl([("model", "Loopback phone")])),
            // Invalid config payloads must be ignored while parsing continues.
            WireProtocol.encode(type: 2, flags: 0, ptsUs: 0, payload: Data([0xff])),
            WireProtocol.encode(type: 5, flags: 0, ptsUs: 0, payload: Data([0xff])),
            WireProtocol.encode(type: 2, flags: 0, ptsUs: 0,
                                payload: WireProtocol.encodeConfig(sps: Data([1]), pps: Data([2]),
                                                                   width: 1920, height: 1080, fps: 30)),
            WireProtocol.encode(type: 1, flags: 1, ptsUs: 42, payload: payload),
            WireProtocol.encode(type: 99, flags: 0, ptsUs: 0, payload: Data([7])),
        ].reduce(into: Data()) { $0.append($1) }

        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state, !didSend else { return }
                didSend = true
                connection.send(content: frames, completion: .contentProcessed { error in
                    if error == nil {
                        sendComplete.fulfill()
                        connection.cancel()
                    }
                })
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
            listener.cancel()
        }

        await fulfillment(of: [transportReady, sendComplete, helloReceived, configReceived, videoReceived, transportLost],
                          timeout: 5)
    }

    func testControlCompletionRunsWhenNoMatchingConnectionExists() async {
        let receiver = StreamReceiver()
        let completed = expectation(description: "control completion is not stranded")

        receiver.sendControl([("cmd", "start")], attempt: UUID()) {
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
    }

}

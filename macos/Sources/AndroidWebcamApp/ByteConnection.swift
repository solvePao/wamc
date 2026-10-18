import Foundation
import Network
import AccessoryUSB

/// Bytes and lifecycle only; framing and camera semantics belong to StreamReceiver.
enum ByteConnectionState {
    case ready
    case failed(Error)
    case cancelled
}

protocol ByteConnection: AnyObject {
    var onStateChange: ((ByteConnectionState) -> Void)? { get set }
    var sourceID: String? { get }
    func start(queue: DispatchQueue)
    func cancel()
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Data?, Bool, Error?) -> Void)
}

extension ByteConnection {
    var sourceID: String? { nil }
}

/// Retains the existing injectable Network boundary for development and checks.
final class TCPByteConnection: ByteConnection {
    var onStateChange: ((ByteConnectionState) -> Void)?
    private let connection: StreamConnection
    init(_ connection: StreamConnection) { self.connection = connection }
    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?(.ready)
            case .failed(let error): self?.onStateChange?(.failed(error))
            case .cancelled: self?.onStateChange?(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data) { completion($0) }
    }
    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive { completion($0, $1, $2) }
    }
}

final class AccessoryByteConnection: ByteConnection, @unchecked Sendable {
    var onStateChange: ((ByteConnectionState) -> Void)?
    private let deviceID: String?
    private let lock = NSLock()
    private var cancelled = false
    private var session: AccessorySession?
    private var callbackQueue: DispatchQueue?
    private let readQueue = DispatchQueue(label: "wamc.usb.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "wamc.usb.write", qos: .userInitiated)

    init(deviceID: String?) { self.deviceID = deviceID }

    func start(queue: DispatchQueue) {
        callbackQueue = queue
        readQueue.async { [self] in
            do {
                let opened = try AccessorySession(deviceID: deviceID, cancelled: { self.isCancelled })
                lock.lock()
                if cancelled {
                    lock.unlock()
                    opened.close()
                    return
                }
                session = opened
                lock.unlock()
                queue.async { [weak self] in self?.onStateChange?(.ready) }
            } catch {
                queue.async { [weak self] in
                    guard let self, !self.isCancelled else { return }
                    self.onStateChange?(.failed(error))
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let opened = session
        session = nil
        lock.unlock()
        // Release on the I/O queue; cancellation never blocks the UI/parser queue.
        readQueue.async { opened?.close() }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        writeQueue.async { [self] in
            let error: Error?
            do { try activeSession().write(data); error = nil }
            catch let failure { error = failure }
            callbackQueue?.async { completion(error) }
        }
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        readQueue.async { [self] in
            do {
                let data = try activeSession().read()
                callbackQueue?.async { completion(data, false, nil) }
            } catch {
                callbackQueue?.async { completion(nil, true, error) }
            }
        }
    }

    var sourceID: String? {
        lock.lock(); defer { lock.unlock() }
        return session?.deviceID
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    private func activeSession() throws -> AccessorySession {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let session else { throw AccessoryUSBError.unavailable("USB disconnected.") }
        return session
    }
}

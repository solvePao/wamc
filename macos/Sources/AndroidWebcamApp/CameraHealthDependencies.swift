import AVFoundation
import AndroidWebcamCore
import CoreMediaIO
import Foundation

protocol CameraUsageObserving {
    func invalidate()
}

extension NSKeyValueObservation: CameraUsageObserving {}

protocol CameraProbeDevice: AnyObject {
    var uniqueID: String { get }
    var isConnected: Bool { get }
    var isInUseByAnotherApplication: Bool { get }
    func observeUsage(_ changed: @escaping () -> Void) -> CameraUsageObserving?
}

extension AVCaptureDevice: CameraProbeDevice {
    func observeUsage(_ changed: @escaping () -> Void) -> CameraUsageObserving? {
        observe(\.isInUseByAnotherApplication, options: [.initial, .new]) { _, _ in changed() }
    }
}

protocol CameraReadbackSession: AnyObject {
    var output: AVCaptureVideoDataOutput { get }
    var canAddInput: Bool { get }
    var canAddOutput: Bool { get }
    func addInput()
    func addOutput()
    func startRunning()
    func stopRunning()
}

final class SystemCameraReadbackSession: CameraReadbackSession {
    private let capture = AVCaptureSession()
    private let input: AVCaptureDeviceInput
    let output = AVCaptureVideoDataOutput()

    init(device: CameraProbeDevice) throws {
        guard let device = device as? AVCaptureDevice else {
            throw NSError(domain: "WAMC.CameraHealth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Camera device is unavailable"])
        }
        input = try AVCaptureDeviceInput(device: device)
        output.alwaysDiscardsLateVideoFrames = true
    }

    var canAddInput: Bool { capture.canAddInput(input) }
    var canAddOutput: Bool { capture.canAddOutput(output) }
    func addInput() { capture.addInput(input) }
    func addOutput() { capture.addOutput(output) }
    func startRunning() { capture.startRunning() }
    func stopRunning() { capture.stopRunning() }
}

struct CameraHealthSnapshotQuery {
    var reader: CoreMediaIOPropertyReading = CoreMediaIOSystemPropertyReader()

    func read() -> CameraHealthSnapshot? {
        guard let ids = try? reader.objects(for: UInt32(kCMIOObjectSystemObject),
                                           selector: UInt32(kCMIOHardwarePropertyDevices)) else { return nil }
        for id in ids {
            guard let uid = try? reader.string(for: id, selector: UInt32(kCMIODevicePropertyDeviceUID)),
                  uid == VirtualCameraDevice.uid,
                  let json = try? reader.string(for: id, selector: CameraHealthSnapshot.selector),
                  let snapshot = try? JSONDecoder().decode(CameraHealthSnapshot.self, from: Data(json.utf8)),
                  snapshot.contractVersion == CameraHealthSnapshot.version else { continue }
            return snapshot
        }
        return nil
    }
}

protocol VirtualCameraProbing: AnyObject {
    var onChange: ((UInt64, VirtualCameraHealth) -> Void)? { get set }
    func update(_ input: VirtualCameraProbe.Input, revision: UInt64)
}

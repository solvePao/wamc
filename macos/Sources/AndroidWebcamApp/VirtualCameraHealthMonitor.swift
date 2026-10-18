import AVFoundation
import AndroidWebcamCore
import Combine
import CoreMediaIO
import Foundation

struct VirtualCameraHealth: Equatable {
    enum Output: String {
        case waiting = "Waiting for phone feed"
        case checking = "Checking camera output…"
        case ready = "Ready for apps"
        case failed = "Check failed"
        case unavailable = "Verification unavailable"
    }
    var output: Output = .waiting
    var detail = "Start the phone stream to check Android Camera."
    var inUse: Bool?

    var usageText: String {
        switch inUse {
        case true: return "In use by another app"
        case false: return "Not currently used by another app"
        case nil: return "Usage unavailable"
        }
    }
}

/// UI-facing lifecycle. Frame callbacks and all capture work belong to the probe queue.
@MainActor
final class VirtualCameraHealthMonitor: ObservableObject {
    @Published private(set) var health = VirtualCameraHealth()
    private let probe: VirtualCameraProbing
    private var input: VirtualCameraProbe.Input?
    private var revision: UInt64 = 0

    init(probe: VirtualCameraProbing = VirtualCameraProbe()) {
        self.probe = probe
        probe.onChange = { [weak self] revision, health in
            Task { @MainActor [weak self] in
                guard let self, self.revision == revision, self.health != health else { return }
                self.health = health
            }
        }
    }

    func update(feedLive: Bool, bridgeAvailable: Bool, extensionEnabled: Bool) {
        let next = VirtualCameraProbe.Input(feedLive: feedLive,
            bridgeAvailable: bridgeAvailable, extensionEnabled: extensionEnabled)
        guard input != next else { return }
        input = next
        revision &+= 1
        // Invalidate green readiness synchronously, before delayed capture callbacks arrive.
        health.output = .waiting
        health.detail = "Waiting for fresh phone video and the camera extension."
        probe.update(next, revision: revision)
    }

    func checkAgain() {
        guard let input else { return }
        revision &+= 1
        probe.update(input, revision: revision)
    }
}

/// One short readback session per feed/extension generation; no images are retained.
final class VirtualCameraProbe: NSObject, VirtualCameraProbing, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Input: Equatable {
        let feedLive: Bool
        let bridgeAvailable: Bool
        let extensionEnabled: Bool
        var eligible: Bool { feedLive && bridgeAvailable && extensionEnabled }
    }

    var onChange: ((UInt64, VirtualCameraHealth) -> Void)?
    private let queue: DispatchQueue
    private let authorization: () -> AVAuthorizationStatus
    private let discoverDevice: () -> CameraProbeDevice?
    private let readSnapshot: () -> CameraHealthSnapshot?
    private let clock: () -> TimeInterval
    private let makeCapture: (CameraProbeDevice) throws -> CameraReadbackSession
    private let automaticRefresh: Bool
    private var timer: DispatchSourceTimer?
    private var input = Input(feedLive: false, bridgeAvailable: false, extensionEnabled: false)
    private var revision: UInt64 = 0
    private var health = VirtualCameraHealth()
    private var device: CameraProbeDevice?
    private var usageObservation: CameraUsageObserving?
    private var session: CameraReadbackSession?
    private var output: AVCaptureVideoDataOutput?
    private var deadline: TimeInterval = 0
    private var initialSnapshot: CameraHealthSnapshot?
    private var instanceID: String?
    private var lastPTS: CMTime = .invalid
    private var sampleCount = 0
    private var lastSourceSequence: UInt64 = 0
    private var attempted = false
    private var verified = false
    private var lastAuthorization: AVAuthorizationStatus?
    init(queue: DispatchQueue = DispatchQueue(label: "wamc.camera-health"),
         authorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         discoverDevice: @escaping () -> CameraProbeDevice? = VirtualCameraProbe.discoverCamera,
         readSnapshot: @escaping () -> CameraHealthSnapshot? = CameraHealthSnapshotQuery().read,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeCapture: @escaping (CameraProbeDevice) throws -> CameraReadbackSession = SystemCameraReadbackSession.init,
         automaticRefresh: Bool = true) {
        self.queue = queue
        self.authorization = authorization
        self.discoverDevice = discoverDevice
        self.readSnapshot = readSnapshot
        self.clock = clock
        self.makeCapture = makeCapture
        self.automaticRefresh = automaticRefresh
        super.init()
    }

    private static func discoverCamera() -> CameraProbeDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
            position: .unspecified).devices.first { $0.uniqueID == VirtualCameraDevice.uid }
    }

    deinit {
        timer?.cancel()
        usageObservation?.invalidate()
        let capture = session
        let videoOutput = output
        queue.async {
            videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            capture?.stopRunning()
        }
    }

    func update(_ input: Input, revision: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopCapture()
            self.input = input
            self.revision = revision
            self.attempted = false
            self.verified = false
            if self.timer == nil && self.automaticRefresh {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(500))
                timer.setEventHandler { [weak self] in self?.refresh() }
                timer.resume()
                self.timer = timer
            }
            self.refresh()
        }
    }

    private func publish(_ state: VirtualCameraHealth.Output, _ detail: String) {
        health.output = state
        health.detail = detail
        onChange?(revision, health)
    }

    func refresh() {
        let authorization = authorization()
        if lastAuthorization != authorization {
            lastAuthorization = authorization
            attempted = false
            verified = false
            stopCapture()
        }
        let discovered = discoverDevice()
        if device?.uniqueID != discovered?.uniqueID || device?.isConnected == false {
            stopCapture()
            usageObservation?.invalidate()
            device = discovered
            attempted = false
            verified = false
            instanceID = nil
            usageObservation = discovered?.observeUsage { [weak self] in
                self?.queue.async { [weak self] in self?.publishUsage() }
            }
        }
        health.inUse = device.map { $0.isInUseByAnotherApplication }
        guard input.feedLive else {
            stopCapture()
            publish(.waiting, "Start the phone stream to check Android Camera.")
            return
        }
        guard input.extensionEnabled else {
            stopCapture()
            publish(.unavailable, "Enable WAMC → Android Camera in Camera Extensions using Setup & Diagnostics.")
            return
        }
        guard input.bridgeAvailable else {
            stopCapture()
            publish(.unavailable, "Waiting for the camera extension's video input. Open Setup & Diagnostics to repair it.")
            return
        }
        guard authorization == .authorized else {
            stopCapture()
            publish(.unavailable, authorization == .notDetermined
                ? "Allow Camera Access in Setup & Diagnostics to verify camera output."
                : "Camera access is blocked. Allow WAMC in System Settings → Privacy & Security → Camera.")
            return
        }
        guard let device, device.isConnected else {
            stopCapture()
            publish(.unavailable, "Android Camera is unavailable to macOS apps. Open Setup & Diagnostics to check the extension.")
            return
        }
        guard let snapshot = readSnapshot() else {
            stopCapture()
            verified = false
            attempted = false
            publish(.unavailable, "Camera verification unavailable — update WAMC. Open Setup & Diagnostics to check the installed extension.")
            return
        }
        if instanceID != snapshot.instanceID {
            stopCapture()
            instanceID = snapshot.instanceID
            attempted = false
            verified = false
        }
        let now = clock()
        guard snapshot.hasFreshSink(at: now) else {
            stopCapture()
            verified = false
            // Retry once delivery resumes, not while the sink is stalled.
            attempted = false
            publish(.failed, "The extension is not receiving fresh phone frames. Check the phone feed or reconnect.")
            return
        }
        if session != nil {
            if now >= deadline {
                stopCapture()
                publish(.failed, "No verified live camera output within five seconds. Check Camera Access and the extension, then Check again.")
            }
            return
        }
        if verified {
            publish(.ready, "Select Android Camera in Photo Booth, FaceTime, or your meeting app.")
        } else if !attempted {
            beginCapture(device, snapshot: snapshot)
        } else {
            onChange?(revision, health)
        }
    }

    private func publishUsage() {
        health.inUse = device.map { $0.isInUseByAnotherApplication }
        onChange?(revision, health)
    }

    private func beginCapture(_ device: CameraProbeDevice, snapshot: CameraHealthSnapshot) {
        attempted = true
        do {
            let capture = try makeCapture(device)
            let videoOutput = capture.output
            guard capture.canAddInput else {
                publish(.failed, "macOS could not open Android Camera. Check the extension, then Check again.")
                return
            }
            capture.addInput()
            guard capture.canAddOutput else {
                publish(.failed, "macOS could not configure camera readback. Check again after repairing the extension.")
                return
            }
            capture.addOutput()
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            session = capture
            output = videoOutput
            initialSnapshot = snapshot
            sampleCount = 0
            lastSourceSequence = snapshot.sinkSequence
            lastPTS = .invalid
            deadline = clock() + 5
            publish(.checking, "Reading Android Camera through the macOS camera interface…")
            capture.startRunning()
        } catch {
            stopCapture()
            publish(.failed, "Could not open Android Camera: \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processSample(sampleBuffer, output: output)
    }

    func processSample(_ sampleBuffer: CMSampleBuffer, output: AVCaptureOutput) {
        guard output === self.output, input.eligible, let initialSnapshot,
              CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric, !lastPTS.isValid || CMTimeCompare(pts, lastPTS) > 0 else { return }
        let now = clock()
        guard now < deadline, let snapshot = readSnapshot(),
              snapshot.instanceID == initialSnapshot.instanceID,
              snapshot.hasFreshSink(at: now), snapshot.hasFreshSource(at: now),
              snapshot.sourceSequence > lastSourceSequence,
              snapshot.sinkSequence > initialSnapshot.sinkSequence else { return }
        lastSourceSequence = snapshot.sourceSequence
        lastPTS = pts
        sampleCount += 1
        guard sampleCount >= 3 else { return }
        verified = true
        stopCapture()
        publish(.ready, "Select Android Camera in Photo Booth, FaceTime, or your meeting app.")
    }

    private func stopCapture() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        session?.stopRunning()
        session = nil
        initialSnapshot = nil
    }
}

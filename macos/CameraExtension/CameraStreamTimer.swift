import Foundation

protocol CameraStreamTiming: AnyObject {
    func start(_ tick: @escaping () -> Void)
    func stop()
}

/// Keeps frame pacing on its own queue. Tests inject a manually advanced timer.
final class CameraStreamTimer: CameraStreamTiming {
    private let queue = DispatchQueue(label: "awc.source")
    private var timer: DispatchSourceTimer?

    func start(_ tick: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler(handler: tick)
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

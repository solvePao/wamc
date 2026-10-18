import Foundation

protocol AppTimerScheduling {
    func repeating(every interval: TimeInterval, action: @escaping @Sendable (Timer) -> Void) -> Timer
}

struct AppTimerScheduler: AppTimerScheduling {
    func repeating(every interval: TimeInterval, action: @escaping @Sendable (Timer) -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: action)
    }
}

import OSLog

enum AppLogger {
    @inline(never) static var connection: Logger { Logger(subsystem: "com.androidwebcam.app", category: "connection") }
    @inline(never) static var discovery: Logger { Logger(subsystem: "com.androidwebcam.app", category: "discovery") }
    @inline(never) static var setup: Logger { Logger(subsystem: "com.androidwebcam.app", category: "setup") }
    @inline(never) static var stream: Logger { Logger(subsystem: "com.androidwebcam.app", category: "stream") }
}

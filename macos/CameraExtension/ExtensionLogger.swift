import OSLog

enum ExtensionLogger {
    @inline(never) static var runtime: Logger {
        Logger(subsystem: "com.androidwebcam.app.CameraExtension", category: "runtime")
    }
}

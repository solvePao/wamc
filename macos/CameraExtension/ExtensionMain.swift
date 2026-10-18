import Foundation
import CoreMediaIO

enum ExtensionBootstrap {
    static func start(
        startService: () -> Void,
        runLoop: () -> Void = CFRunLoopRun
    ) {
        startService()
        runLoop()
    }
}

#if !WAMC_COVERAGE_TESTING
@main
enum ExtensionMain {
    static func main() {
        ExtensionBootstrap.start {
            let providerSource = ProviderSource()
            CMIOExtensionProvider.startService(provider: providerSource.provider)
        }
    }
}
#endif

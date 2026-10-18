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
        let providerSource = ProviderSource()
        // CoreMediaIO keeps a weak source reference. Retain the entire source
        // graph until the service run loop exits so client callbacks stay valid.
        withExtendedLifetime(providerSource) {
            ExtensionBootstrap.start {
                CMIOExtensionProvider.startService(provider: providerSource.provider)
            }
        }
    }
}
#endif

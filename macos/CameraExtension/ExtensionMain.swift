import Foundation
import CoreMediaIO

@main
enum ExtensionMain {
    static func main() {
        let providerSource = ProviderSource()
        CMIOExtensionProvider.startService(provider: providerSource.provider)
        CFRunLoopRun()
    }
}

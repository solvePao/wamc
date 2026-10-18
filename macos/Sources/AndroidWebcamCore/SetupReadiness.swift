import Foundation

/// Registration and a successful host preview do not prove virtual-camera delivery.
public enum SetupReadiness: Equatable {
    case needsInstallation
    case invalidPackage
    case needsExtension
    case waitingForSink
    case waitingForPhone
    case streaming

    public static func isApplicationsInstall(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") && path.hasSuffix(".app")
    }

    public static func evaluate(installed: Bool, validPackage: Bool,
                                extensionEnabled: Bool, sinkRegistered: Bool,
                                sendingFrames: Bool) -> Self {
        guard installed else { return .needsInstallation }
        guard validPackage else { return .invalidPackage }
        guard extensionEnabled else { return .needsExtension }
        guard sinkRegistered else { return .waitingForSink }
        return sendingFrames ? .streaming : .waitingForPhone
    }
}

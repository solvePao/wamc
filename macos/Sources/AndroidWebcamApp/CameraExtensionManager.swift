import Foundation
import AppKit
import SystemExtensions

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionBundleID = "com.androidwebcam.app.CameraExtension"

    enum Status: Equatable {
        case unknown
        case notInstalled
        case requiresApproval
        case active
        case failed(String)

        var description: String {
            switch self {
            case .unknown: return "Virtual camera: Ready to activate"
            case .notInstalled: return "Virtual camera: Not installed"
            case .requiresApproval: return "Virtual camera: Approval required in System Settings"
            case .active: return "Virtual camera: Active"
            case .failed(let err): return "Virtual camera error: \(err)"
            }
        }
    }

    @Published var status: Status = .unknown

    override init() {
        super.init()
    }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.status = .requiresApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.status = .active
            case .willCompleteAfterReboot:
                self.status = .requiresApproval
            @unknown default:
                self.status = .active
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFailWithError error: Error) {
        Task { @MainActor in
            self.status = .failed(error.localizedDescription)
        }
    }
}

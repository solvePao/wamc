import Foundation
import AppKit
import SystemExtensions
import Combine

@MainActor
protocol CameraExtensionServicing: AnyObject {
    var status: CameraExtensionManager.Status { get }
    var statusPublisher: AnyPublisher<CameraExtensionManager.Status, Never> { get }
    func activate()
    func refreshStatus()
    func openSystemSettings()
}

struct CameraExtensionRequestState {
    enum RequestKind { case activation, properties }
    enum Completion { case completed, requiresRestart, unexpected }

    private(set) var activationPending = false
    private(set) var propertiesPending = false

    mutating func beginActivation() -> Bool {
        guard !activationPending else { return false }
        activationPending = true
        return true
    }

    mutating func beginProperties(currentStatus: CameraExtensionManager.Status) -> Bool {
        guard !propertiesPending, !activationPending, currentStatus != .requiresRestart else { return false }
        propertiesPending = true
        return true
    }

    mutating func finishActivation(_ completion: Completion) -> CameraExtensionManager.Status? {
        activationPending = false
        switch completion {
        case .completed: return nil
        case .requiresRestart: return .requiresRestart
        case .unexpected: return .failed("Unexpected installation result. Check Setup & Diagnostics.")
        }
    }

    mutating func fail(_ kind: RequestKind, message: String) -> CameraExtensionManager.Status {
        switch kind {
        case .activation: activationPending = false
        case .properties: propertiesPending = false
        }
        return .failed(message)
    }

    mutating func propertiesFound(installed: Bool, enabled: Bool,
                                  awaitingApproval: Bool) -> CameraExtensionManager.Status {
        propertiesPending = false
        return CameraExtensionManager.status(installed: installed, enabled: enabled,
                                             awaitingApproval: awaitingApproval)
    }
}

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate,
                                    CameraExtensionServicing {
    nonisolated static let extensionBundleID = "com.androidwebcam.app.CameraExtension"

    enum Status: Equatable {
        case unknown
        case notInstalled
        case activating
        case requiresApproval
        case disabled
        case requiresRestart
        case active
        case failed(String)

        var description: String {
            switch self {
            case .unknown: return "Virtual camera: Ready to activate"
            case .notInstalled: return "Virtual camera: Not installed"
            case .activating: return "Virtual camera: Installing…"
            case .requiresApproval: return "Virtual camera: Approval required in System Settings"
            case .disabled: return "Virtual camera: Enable Android Camera in System Settings"
            case .requiresRestart: return "Virtual camera: Restart your Mac to finish updating"
            case .active: return "Virtual camera: Active"
            case .failed(let err): return "Virtual camera error: \(err)"
            }
        }
    }

    nonisolated static func status(installed: Bool, enabled: Bool, awaitingApproval: Bool) -> Status {
        if enabled { return .active }
        if awaitingApproval { return .requiresApproval }
        if installed { return .disabled }
        return .notInstalled
    }

    @Published var status: Status = .unknown
    var statusPublisher: AnyPublisher<Status, Never> { $status.eraseToAnyPublisher() }
    private var activationRequest: OSSystemExtensionRequest?
    private var propertiesRequest: OSSystemExtensionRequest?
    private var requestState = CameraExtensionRequestState()

    private let submitRequest: (OSSystemExtensionRequest) -> Void
    private let openURL: (URL) -> Void

    init(submitRequest: ((OSSystemExtensionRequest) -> Void)? = nil,
         openURL: ((URL) -> Void)? = nil) {
        self.submitRequest = submitRequest ?? { OSSystemExtensionManager.shared.submitRequest($0) }
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        super.init()
    }

    func activate() {
        guard requestState.beginActivation() else { return }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        status = .activating
        submitRequest(request)
    }

    func refreshStatus() {
        guard requestState.beginProperties(currentStatus: status) else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionBundleID, queue: .main)
        propertiesRequest = request
        request.delegate = self
        submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        submitRequest(request)
    }

    func completeActivation(_ completion: CameraExtensionRequestState.Completion,
                            refreshAfterCompletion: Bool = true) {
        activationRequest = nil
        if let resolvedStatus = requestState.finishActivation(completion) {
            status = resolvedStatus
        } else if refreshAfterCompletion {
            refreshStatus()
        }
    }

    func failRequest(_ kind: CameraExtensionRequestState.RequestKind, message: String) {
        switch kind {
        case .activation: activationRequest = nil
        case .properties: propertiesRequest = nil
        }
        status = requestState.fail(kind, message: message)
    }

    func resolveProperties(installed: Bool, enabled: Bool, awaitingApproval: Bool) {
        propertiesRequest = nil
        let resolvedStatus = requestState.propertiesFound(installed: installed, enabled: enabled,
                                                          awaitingApproval: awaitingApproval)
        if status != resolvedStatus { status = resolvedStatus }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            openURL(url)
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
            let completion: CameraExtensionRequestState.Completion
            switch result {
            case .completed: completion = .completed
            case .willCompleteAfterReboot: completion = .requiresRestart
            @unknown default: completion = .unexpected
            }
            self.completeActivation(completion)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFailWithError error: Error) {
        Task { @MainActor in
            let kind: CameraExtensionRequestState.RequestKind =
                request === self.propertiesRequest ? .properties : .activation
            self.failRequest(kind, message: error.localizedDescription)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             foundProperties properties: [OSSystemExtensionProperties]) {
        let current = properties.filter { !$0.isUninstalling }
        Task { @MainActor in
            self.resolveProperties(installed: !current.isEmpty,
                                   enabled: current.contains { $0.isEnabled },
                                   awaitingApproval: current.contains { $0.isAwaitingUserApproval })
        }
    }
}

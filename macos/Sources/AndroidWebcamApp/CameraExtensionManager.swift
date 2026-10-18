import Foundation
import AppKit
import SystemExtensions
import Combine
import OSLog

@MainActor
protocol CameraExtensionServicing: AnyObject {
    var status: CameraExtensionManager.Status { get }
    var statusPublisher: AnyPublisher<CameraExtensionManager.Status, Never> { get }
    func activate()
    func repair()
    func refreshStatus()
    func openSystemSettings()
}

extension CameraExtensionServicing {
    func repair() { activate() }
}

struct CameraExtensionRequestState {
    enum RequestKind { case activation, properties }
    enum Completion { case completed, requiresRestart, unexpected }

    private(set) var activationPending = false
    private(set) var propertiesPending = false

    mutating func beginActivation() -> Bool {
        guard !activationPending, !propertiesPending else { return false }
        activationPending = true
        return true
    }

    mutating func beginProperties(currentStatus: CameraExtensionManager.Status) -> Bool {
        guard !propertiesPending, !activationPending else { return false }
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

    @Published var status: Status = .unknown {
        didSet {
            guard oldValue != status else { return }
            AppLogger.setup.info("Camera extension state: \(self.status.logName, privacy: .public)")
        }
    }
    @Published private(set) var lastRequestError: String?
    var statusPublisher: AnyPublisher<Status, Never> { $status.eraseToAnyPublisher() }
    private var activationRequest: OSSystemExtensionRequest?
    private var propertiesRequest: OSSystemExtensionRequest?
    private var requestState = CameraExtensionRequestState()
    private var activationAfterInspection = false
    private var repairAfterInspection = false

    private let submitRequest: (OSSystemExtensionRequest) -> Void
    private let openURL: (URL) -> Void

    init(submitRequest: ((OSSystemExtensionRequest) -> Void)? = nil,
         openURL: ((URL) -> Void)? = nil) {
        self.submitRequest = submitRequest ?? { OSSystemExtensionManager.shared.submitRequest($0) }
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        super.init()
    }

    func activate() {
        inspectBeforeActivation(repair: false)
    }

    func repair() {
        inspectBeforeActivation(repair: true)
    }

    private func inspectBeforeActivation(repair: Bool) {
        guard !requestState.activationPending, status != .requiresRestart else { return }
        activationAfterInspection = true
        repairAfterInspection = repairAfterInspection || repair
        refreshStatus()
    }

    private func submitActivation() {
        guard requestState.beginActivation() else { return }
        lastRequestError = nil
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
        activationAfterInspection = false
        repairAfterInspection = false
        lastRequestError = message
        let failureStatus = requestState.fail(kind, message: message)
        if kind == .properties, status == .requiresRestart || status == .requiresApproval {
            return
        }
        status = failureStatus
    }

    func resolveProperties(installed: Bool, enabled: Bool, awaitingApproval: Bool) {
        propertiesRequest = nil
        lastRequestError = nil
        let resolvedStatus = requestState.propertiesFound(installed: installed, enabled: enabled,
                                                          awaitingApproval: awaitingApproval)
        let shouldActivate = activationAfterInspection
        let shouldRepair = repairAfterInspection
        activationAfterInspection = false
        repairAfterInspection = false
        if status == .requiresRestart, !enabled { return }
        if status == .requiresApproval, !installed, !enabled { return }
        if status != resolvedStatus { status = resolvedStatus }
        if shouldActivate, !awaitingApproval, (!installed || shouldRepair) {
            submitActivation()
        }
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
            guard request === self.activationRequest else { return }
            self.status = .requiresApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard request === self.activationRequest else { return }
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
            let kind: CameraExtensionRequestState.RequestKind
            if request === self.propertiesRequest {
                kind = .properties
            } else if request === self.activationRequest {
                kind = .activation
            } else {
                return
            }
            let nsError = error as NSError
            AppLogger.setup.error("Camera extension request failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            self.failRequest(kind, message: error.localizedDescription)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             foundProperties properties: [OSSystemExtensionProperties]) {
        Task { @MainActor in
            guard request === self.propertiesRequest else { return }
            let current = properties.filter { property in
                !property.isUninstalling && self.matchesBundledVersion(property)
            }
            self.resolveProperties(installed: !current.isEmpty,
                                   enabled: current.contains { $0.isEnabled },
                                   awaitingApproval: current.contains { $0.isAwaitingUserApproval })
        }
    }

    private func matchesBundledVersion(_ property: OSSystemExtensionProperties) -> Bool {
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(Self.extensionBundleID).systemextension")
        guard let bundle = Bundle(url: extensionURL),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            // Command-line builds and test bundles do not embed a camera extension.
            return true
        }
        return property.bundleVersion == version && property.bundleShortVersion == shortVersion
    }
}

private extension CameraExtensionManager.Status {
    var logName: String {
        switch self {
        case .unknown: return "unknown"
        case .notInstalled: return "notInstalled"
        case .activating: return "activating"
        case .requiresApproval: return "requiresApproval"
        case .disabled: return "disabled"
        case .requiresRestart: return "requiresRestart"
        case .active: return "active"
        case .failed: return "failed"
        }
    }
}

import AndroidWebcamCore

/// The window and native menu apply the same source-selection action.
@MainActor
struct SourceSelection {
    let model: AppModel
    let target: ConnectionTarget

    func select() { model.selectSource(target) }
}

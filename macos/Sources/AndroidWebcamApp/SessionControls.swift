import SwiftUI

struct SessionControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let action = model.sessionAction
        ControlSection(title: "Stream", symbol: "video") {
            Text(action.sourceLabel)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                if action.isProgress { ProgressView().controlSize(.small) }
                Text(action.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: model.performSessionAction) {
                Label(action.title, systemImage: action.symbol)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .wamcActionStyle(prominent: true)
            .disabled(!action.enabled)
            .accessibilityLabel(action.title)
            .help(action.action == .start ? "Connect to the selected source and start streaming"
                  : "Stop or cancel this streaming session")
        }
    }
}

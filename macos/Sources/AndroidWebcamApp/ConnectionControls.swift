import SwiftUI

struct ConnectionControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ControlSection(title: "Source", symbol: "cable.connector") {
            sourceRow(for: .usb(serial: nil), title: "USB", subtitle: "Wired phone", symbol: "cable.connector")

            VStack(alignment: .leading, spacing: 12) {
                Text("PHONES ON WI-FI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.wifiStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.visibleWifiDevices.isEmpty {
                    Text("Open WAMC on your phone and use the same Wi-Fi network. Keep Wi-Fi discovery enabled on the phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.visibleWifiDevices) { device in
                    sourceRow(for: .wifi(device), title: device.displayName,
                              subtitle: model.isTrusted(device) ? "Trusted phone" : "New phone", symbol: "wifi")
                        .contextMenu {
                            if model.isTrusted(device) {
                                Button("Forget", role: .destructive) { model.forgetDevice(device) }
                            }
                        }
                }
            }

            ForEach(manualSources, id: \.key) { target in
                sourceRow(for: target, title: target.label, subtitle: "Manual Wi-Fi", symbol: "wifi")
            }

            DisclosureGroup("Manual address") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("192.168.1.20 or host:port", text: $model.manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Manual phone address")
                        .onSubmit(model.useManualAddress)
                    Button("Use address", action: model.useManualAddress)
                        .disabled(model.manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Use when your network blocks automatic discovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !model.nativeWebcams.isEmpty {
                Label("Native USB webcam: \(model.nativeWebcams.joined(separator: ", ")). Select it directly in your meeting app.",
                      systemImage: "web.camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var manualSources: [ConnectionTarget] {
        var sources: [ConnectionTarget] = []
        if case .address = model.selectedSource { sources.append(model.selectedSource) }
        if let active = model.connectionState.target, case .address = active,
           !sources.contains(where: { $0.key == active.key }) { sources.append(active) }
        return sources
    }

    private func sourceRow(for target: ConnectionTarget, title: String, subtitle: String, symbol: String) -> some View {
        let selected = model.isSourceSelected(target)
        let active = model.isSourceActive(target)
        let selection = SourceSelection(model: model, target: target)
        return Button(action: selection.select) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(active ? "\(subtitle) · Active" : subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(selected ? "Selected source" : "Select source")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .wamcGlassSurface()
    }

}

struct AutomationPreferences: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Start streaming automatically", isOn: $model.startStreamingAutomatically)
                .help("Start streaming when an available phone can connect automatically")
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLoginEnabled }, set: model.setLaunchAtLogin))
            if model.launchAtLoginRequiresApproval {
                Button("Approve in Login Items…", action: model.launchAtLogin.openLoginItemsSettings)
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}

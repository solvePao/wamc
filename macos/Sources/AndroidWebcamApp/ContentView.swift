import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassControlGroup {
            HStack(spacing: 0) {
                PreviewPane(model: model)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SessionControls(model: model)
                        Divider()
                        ConnectionControls(model: model)
                        Divider()
                        CameraControls(connected: model.connected, facingBack: model.facingBack,
                                       quality: model.qualityMode, setQuality: model.setQuality,
                                       switchCamera: model.switchCamera, rotate: model.rotate)
                            .equatable()
                        Divider()
                        DisclosureGroup {
                            AutomationPreferences(model: model)
                                .padding(.top, 12)
                        } label: {
                            Label("Preferences", systemImage: "slider.horizontal.3")
                                .font(.headline)
                        }
                    }
                    .padding(20)
                }
                .frame(width: 320)
            }
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 10) {
                    StatusBadge(title: model.connected ? model.transportLabel : "Disconnected",
                                symbol: model.connected ? "checkmark.circle.fill" : "circle.dashed",
                                color: model.connected ? .green : .secondary)
                    Text(model.deviceLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.deviceLabel)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.setup.showSetup = true } label: {
                    Label("Setup", systemImage: "gearshape")
                }
                .help("Setup & Diagnostics")
            }
        }
        .sheet(isPresented: Binding(get: { model.setup.showSetup },
                                    set: { model.setup.showSetup = $0 })) {
            SetupView(model: model)
        }
        .task {
            if SetupModel.needsFirstRunSetup {
                await Task.yield()
                model.setup.showSetup = true
            }
        }
        .onAppear {
            model.previewVisible = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            model.previewVisible = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

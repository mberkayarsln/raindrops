import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Rain") {
                LabeledContent("Wind") {
                    HStack(spacing: 10) {
                        Slider(value: binding(\.wind), in: AppSettings.windRange, step: AppSettings.windStep)
                        Text(AppSettings.windTitle(for: model.settings.wind))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                Picker("Direction", selection: binding(\.windDirection)) {
                    ForEach(WindDirection.allCases, id: \.self) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.settings.wind == 0)
                Picker("Drop limit", selection: binding(\.maximumDropCount)) {
                    ForEach(AppSettings.dropCountOptions, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
            }

            Section("Pool") {
                Toggle("Pool at bottom", isOn: binding(\.isPoolEnabled))
                LabeledContent("Maximum level") {
                    HStack(spacing: 10) {
                        Slider(value: binding(\.poolMaximumFraction), in: AppSettings.poolFractionRange)
                        Text("\(Int((model.settings.poolMaximumFraction * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!model.settings.isPoolEnabled)
            }

            Section {
                Toggle("Rain sound", isOn: binding(\.isSoundEnabled))
                LabeledContent("Volume") {
                    Slider(value: binding(\.soundVolume), in: AppSettings.volumeRange)
                }
                .disabled(!model.settings.isSoundEnabled)
                Toggle("Thunder and lightning", isOn: binding(\.isStormEnabled))
                LabeledContent("Lightning") {
                    Button("Strike Now") { model.strikeLightning() }
                        .disabled(!model.canStrikeLightning)
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Lightning strikes now and then in Rain and Downpour. Drizzle stays calm.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Displays", selection: binding(\.screenSelection)) {
                    ForEach(ScreenSelection.allCases, id: \.self) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                Toggle("Cursor interaction", isOn: binding(\.isCursorInteractionEnabled))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.launchesAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }
}

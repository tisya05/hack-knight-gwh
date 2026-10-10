import SwiftUI

/// Development settings for choosing mock services and debugging the demo.
/// Service changes are saved immediately and take effect after the app restarts.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("debug.showMarkers") private var showDebugMarkers = true
    @AppStorage("debug.disableLiDAR") private var disableLiDAR = false

    @State private var serviceFlags = ServiceFlags.current()
    @State private var restartRequired = false

    var body: some View {
        NavigationStack {
            Form {
                if restartRequired {
                    Section {
                        Label(
                            "Close and reopen Echora to apply service changes.",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Restart Echora to apply service changes")
                    }
                }

                serviceSection
                debugSection
                configurationSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var serviceSection: some View {
        Section {
            serviceToggle(
                "Camera and AR",
                systemImage: "camera.fill",
                keyPath: \.mockPerception,
                defaultsKey: "flag.mockPerception"
            )
            serviceToggle(
                "Object locator",
                systemImage: "viewfinder",
                keyPath: \.mockLocator,
                defaultsKey: "flag.mockLocator"
            )
            serviceToggle(
                "Head tracking",
                systemImage: "airpods",
                keyPath: \.mockHeadTracking,
                defaultsKey: "flag.mockHeadTracking"
            )
            serviceToggle(
                "Spatial audio",
                systemImage: "speaker.wave.2.fill",
                keyPath: \.mockAudio,
                defaultsKey: "flag.mockAudio"
            )
            serviceToggle(
                "Voice recognition",
                systemImage: "mic.fill",
                keyPath: \.mockVoice,
                defaultsKey: "flag.mockVoice"
            )
            serviceToggle(
                "Telemetry",
                systemImage: "chart.line.uptrend.xyaxis",
                keyPath: \.mockTelemetry,
                defaultsKey: "flag.mockTelemetry"
            )
        } header: {
            Text("Mock services")
        } footer: {
            Text(
                "Keep these on for simulator testing. Turn a service off to request its real implementation, then restart the app. Services that are not available yet still use a mock."
            )
        }
    }

    private var debugSection: some View {
        Section("Debug tools") {
            Toggle(isOn: $showDebugMarkers) {
                Label("Show AR markers", systemImage: "scope")
            }

            Toggle(isOn: $disableLiDAR) {
                Label("Disable LiDAR", systemImage: "sensor.tag.radiowaves.forward")
            }
        }
    }

    private var configurationSection: some View {
        Section {
            LabeledContent("Phone position", value: "Chest mount")
            LabeledContent("Ear height offset", value: "0.35 m")

            VStack(alignment: .leading, spacing: EchoraTheme.smallSpacing) {
                Text("Backend URL")
                    .font(.subheadline.weight(.semibold))

                Text(Config.backendBaseURL.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(EchoraTheme.secondaryText)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Current configuration")
        } footer: {
            Text(
                "The listener rig is read-only for now because it is owned by the app configuration module."
            )
        }
    }

    private func serviceToggle(
        _ title: String,
        systemImage: String,
        keyPath: WritableKeyPath<ServiceFlags, Bool>,
        defaultsKey: String
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: {
                    serviceFlags[keyPath: keyPath]
                },
                set: { newValue in
                    serviceFlags[keyPath: keyPath] = newValue
                    UserDefaults.standard.set(newValue, forKey: defaultsKey)
                    restartRequired = true
                }
            )
        ) {
            Label(title, systemImage: systemImage)
        }
    }
}

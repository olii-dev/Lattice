import SwiftUI

/// Account, model, and simulator configuration in a dedicated window (Command+, toolbar gear, or hub).
struct AccountSettingsView: View {
    @ObservedObject var simulatorStore: SimulatorStore
    @ObservedObject var generationState: LatticeGenerationState

    @AppStorage("anthropicAPIKey") private var anthropicKey = ""
    @AppStorage("openAIAPIKey") private var openAIKey = ""
    @AppStorage("zaiAPIKey") private var zaiKey = ""
    @AppStorage("zaiUseCodingEndpoint") private var zaiUseCodingEndpoint = true
    @AppStorage("selectedProvider") private var selectedProvider = "anthropic"
    @AppStorage("selectedSimulatorID") private var selectedSimulatorID = ""
    @AppStorage("selectedModel") private var selectedModel = "claude-sonnet-4-6"
    @AppStorage("latticeLocalRunDestination") private var latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSSimulator.rawValue
    @AppStorage("latticeAppearancePreference") private var latticeAppearancePreference = "system"
    @AppStorage("latticeShowComposerTips") private var latticeShowComposerTips = true
    @AppStorage("latticeAccentTag") private var latticeAccentTag = "system"
    @AppStorage("latticeGlobalDevelopmentTeam") private var latticeGlobalDevelopmentTeam = ""

    private var currentProvider: LLMProvider {
        LLMProvider(rawValue: selectedProvider) ?? .anthropic
    }

    private var localRunDestination: LatticeLocalRunDestination {
        LatticeLocalRunDestination(rawValue: latticeLocalRunDestinationRaw) ?? .iOSSimulator
    }

    private var simulatorsForSettings: [SimulatorOption] {
        switch localRunDestination {
        case .iOSSimulator:
            return simulatorStore.simulators.filter { $0.matches(filter: .iOS) }
        case .iOSDevice:
            return []
        case .watchOSSimulator:
            return simulatorStore.simulators.filter { $0.matches(filter: .watchOS) }
        case .macOS:
            return []
        }
    }

    private var devicesForSettings: [ConnectedDeviceOption] {
        simulatorStore.connectedDevices
    }

    private var settingsPreferredAppearance: ColorScheme? {
        switch latticeAppearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var settingsAccentTint: Color? {
        switch latticeAccentTag {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        default: return nil
        }
    }

    private var currentKeyNonEmpty: Bool {
        switch currentProvider {
        case .anthropic: return !anthropicKey.isEmpty
        case .openAI: return !openAIKey.isEmpty
        case .zai: return !zaiKey.isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $latticeAppearancePreference) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)

                Picker("Accent", selection: $latticeAccentTag) {
                    Text("System").tag("system")
                    Text("Blue").tag("blue")
                    Text("Purple").tag("purple")
                    Text("Green").tag("green")
                    Text("Orange").tag("orange")
                    Text("Pink").tag("pink")
                }
                .pickerStyle(.menu)

                Toggle("Show composer tips", isOn: $latticeShowComposerTips)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Applies to the main Lattice window.")
            }

            Section {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(generationState.isGenerating)

                HStack(alignment: .center, spacing: 10) {
                    SecureField("API key", text: keyBinding)
                        .textFieldStyle(.roundedBorder)
                    if currentKeyNonEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityLabel("API key saved on this device")
                    }
                }

                Picker("Model", selection: $selectedModel) {
                    ForEach(currentProvider.models, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(generationState.isGenerating)

                if currentProvider == .zai {
                    Toggle("GLM Coding Plan API", isOn: $zaiUseCodingEndpoint)
                        .disabled(generationState.isGenerating)
                }
            } header: {
                Text("AI account")
            } footer: {
                Text("Keys stay on this device and are sent only to the selected provider.")
            }

            Section {
                Picker("Run destination", selection: $latticeLocalRunDestinationRaw) {
                    ForEach(LatticeLocalRunDestination.allCases) { dest in
                        Text(dest.settingsLabel).tag(dest.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if localRunDestination != .macOS {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Picker(localRunDestination == .iOSDevice ? "Device" : "Simulator", selection: $selectedSimulatorID) {
                            Text("None").tag("")
                            if localRunDestination == .iOSDevice {
                                ForEach(devicesForSettings) { device in
                                    Text(device.label).tag(device.id)
                                }
                            } else {
                                ForEach(simulatorsForSettings) { simulator in
                                    Text(simulator.label).tag(simulator.id)
                                }
                            }
                        }
                        .disabled(localRunDestination == .iOSDevice ? devicesForSettings.isEmpty : simulatorsForSettings.isEmpty)

                        Button {
                            simulatorStore.refresh()
                        } label: {
                            if simulatorStore.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh simulator list")
                    }

                    if let loadError = simulatorStore.loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("macOS builds target “My Mac”; no simulator pick is needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Build & Run")
            } footer: {
                Text("All destination kinds are available here. ⌘R in the main window uses the selected destination; pick a matching simulator or device when needed.")
            }

            Section {
                TextField("Default Team ID (optional)", text: $latticeGlobalDevelopmentTeam)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Signing default")
            } footer: {
                Text("Used when a project leaves Team ID blank in the Project inspector.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 400, alignment: .topLeading)
        .padding(.vertical, 8)
        .preferredColorScheme(settingsPreferredAppearance)
        .tint(settingsAccentTint)
        .task {
            simulatorStore.refresh()
        }
        .onChange(of: selectedProvider) { _, _ in
            let provider = LLMProvider(rawValue: selectedProvider) ?? .anthropic
            if !provider.models.contains(where: { $0.id == selectedModel }) {
                selectedModel = provider.defaultModel
            }
        }
        .onChange(of: simulatorStore.simulators) { _, simulators in
            if localRunDestination != .iOSDevice,
               !selectedSimulatorID.isEmpty,
               !simulators.contains(where: { $0.id == selectedSimulatorID }) {
                selectedSimulatorID = ""
            }
        }
        .onChange(of: simulatorStore.connectedDevices) { _, _ in
            if localRunDestination == .iOSDevice,
               !selectedSimulatorID.isEmpty,
               !devicesForSettings.contains(where: { $0.id == selectedSimulatorID }) {
                selectedSimulatorID = ""
            }
        }
        .onChange(of: latticeLocalRunDestinationRaw) { _, _ in
            if !selectedSimulatorID.isEmpty {
                let valid: Bool = {
                    switch localRunDestination {
                    case .iOSDevice:
                        return devicesForSettings.contains(where: { $0.id == selectedSimulatorID })
                    case .iOSSimulator, .watchOSSimulator:
                        return simulatorsForSettings.contains(where: { $0.id == selectedSimulatorID })
                    case .macOS:
                        return true
                    }
                }()
                if !valid { selectedSimulatorID = "" }
            }
        }
    }

    private var keyBinding: Binding<String> {
        switch currentProvider {
        case .anthropic: $anthropicKey
        case .openAI: $openAIKey
        case .zai: $zaiKey
        }
    }
}

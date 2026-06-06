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

    private var localRunSelectionTitle: String {
        switch localRunDestination {
        case .macOS:
            return "My Mac"
        case .iOSDevice:
            return devicesForSettings.first(where: { $0.id == selectedSimulatorID })?.label ?? "No device selected"
        case .iOSSimulator:
            return simulatorsForSettings.first(where: { $0.id == selectedSimulatorID })?.label ?? "No iPhone simulator selected"
        case .watchOSSimulator:
            return simulatorsForSettings.first(where: { $0.id == selectedSimulatorID })?.label ?? "No Apple Watch simulator selected"
        }
    }

    private var localRunHelperText: String {
        switch localRunDestination {
        case .macOS:
            return "The Run button will build and launch the current project on this Mac."
        case .iOSDevice:
            return selectedSimulatorID.isEmpty
                ? "Pick a connected iPhone or iPad for one-click local runs."
                : "The Run button will build and launch on the selected connected device."
        case .iOSSimulator:
            return selectedSimulatorID.isEmpty
                ? "Pick the iPhone simulator Lattice should use from the main window."
                : "The Run button will build, install, and launch in the selected iPhone simulator."
        case .watchOSSimulator:
            return selectedSimulatorID.isEmpty
                ? "Pick the Apple Watch simulator Lattice should use from the main window."
                : "The Run button will build, install, and launch in the selected watchOS simulator."
        }
    }

    var body: some View {
        ZStack {
            LatticeWindowBackdrop()
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

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
                LabeledContent("Current run target") {
                    Text(localRunSelectionTitle)
                        .fontWeight(.semibold)
                }

                Text(localRunHelperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Platform", selection: $latticeLocalRunDestinationRaw) {
                    ForEach(LatticeLocalRunDestination.allCases) { dest in
                        Text(dest.settingsLabel).tag(dest.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if localRunDestination != .macOS {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Picker(localRunDestination == .iOSDevice ? "Device" : "Target", selection: $selectedSimulatorID) {
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
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Refreshing")
                                }
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(localRunDestination == .iOSDevice ? "Refresh connected devices" : "Refresh simulator list")
                    }

                    if let loadError = simulatorStore.loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("No extra target picker is needed for Mac apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Local Build & Run")
            } footer: {
                Text("This controls what the Run button in the main window uses. Pick the platform first, then choose the exact simulator or device when needed.")
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
        .scrollContentBackground(.hidden)
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
    }

    private var keyBinding: Binding<String> {
        switch currentProvider {
        case .anthropic: $anthropicKey
        case .openAI: $openAIKey
        case .zai: $zaiKey
        }
    }
}

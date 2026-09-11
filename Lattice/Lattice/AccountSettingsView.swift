import SwiftUI

/// Account, model, and simulator configuration in a dedicated window (Command+, toolbar gear, or hub).
struct AccountSettingsView: View {
    @ObservedObject var simulatorStore: SimulatorStore
    @ObservedObject var generationState: LatticeGenerationState

    @ObservedObject private var keyStore = APIKeyStore.shared
    @ObservedObject private var customProviderStore = CustomProviderStore.shared
    @State private var customProviderEditor: CustomProvider?
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

    private var isCustomSelection: Bool {
        activeCustomProvider != nil
    }

    private var activeCustomProvider: CustomProvider? {
        customProviderStore.provider(selectionID: selectedProvider)
    }

    private var activeModelOptions: [LLMModelOption] {
        activeCustomProvider?.modelOptions ?? currentProvider.models
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
        if let custom = activeCustomProvider {
            return !keyStore.customKey(id: custom.id).isEmpty
        }
        return !keyStore.key(for: currentProvider).isEmpty
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
                    Section("Built-in") {
                        ForEach(LLMProvider.allCases) { p in
                            Text(p.displayName).tag(p.rawValue)
                        }
                    }
                    if !customProviderStore.providers.isEmpty {
                        Section("Custom") {
                            ForEach(customProviderStore.providers) { provider in
                                Text(provider.name).tag(provider.selectionID)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(generationState.isGenerating)

                HStack(alignment: .center, spacing: 10) {
                    SecureField(keyFieldPrompt, text: keyBinding)
                        .textFieldStyle(.roundedBorder)
                    if currentKeyNonEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityLabel("API key saved on this device")
                    }
                }
                if isCustomSelection {
                    Text("Local providers like Ollama and LM Studio don't need a key — leave this empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Model", selection: $selectedModel) {
                    if activeModelOptions.isEmpty {
                        Text("No models — add some").tag("")
                    }
                    ForEach(activeModelOptions) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(generationState.isGenerating)

                if isCustomSelection, let custom = activeCustomProvider {
                    Button("Edit “\(custom.name)”…") {
                        customProviderEditor = custom
                    }
                }

                Button("Add a custom provider…") {
                    customProviderEditor = CustomProvider(name: "", baseURL: "", protocolKind: .openAICompatible)
                }

                if currentProvider == .zai, !isCustomSelection {
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
        .onChange(of: selectedProvider) { _, newValue in
            if let custom = customProviderStore.provider(selectionID: newValue) {
                if !custom.modelIDs.contains(selectedModel) {
                    selectedModel = custom.defaultModel
                }
                return
            }
            guard let provider = LLMProvider(rawValue: newValue) else { return }
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
        .sheet(item: $customProviderEditor) { provider in
            CustomProviderEditorSheet(initialProvider: provider) { saved in
                selectedProvider = saved.selectionID
                if !saved.modelIDs.contains(selectedModel) {
                    selectedModel = saved.defaultModel
                }
            }
        }
        }
    }

    private var keyFieldPrompt: String {
        isCustomSelection ? "API key (optional)" : "API key"
    }

    private var keyBinding: Binding<String> {
        if let custom = activeCustomProvider {
            return Binding<String>(
                get: { keyStore.customKey(id: custom.id) },
                set: { keyStore.setCustomKey($0, id: custom.id) }
            )
        }
        return Binding<String>(
            get: { keyStore.key(for: currentProvider) },
            set: { keyStore.setKey($0, for: currentProvider) }
        )
    }
}

/// Add/edit sheet for custom OpenAI- or Anthropic-compatible providers.
private struct CustomProviderEditorSheet: View {
    let initialProvider: CustomProvider
    var onSaved: (CustomProvider) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyStore = APIKeyStore.shared
    @ObservedObject private var store = CustomProviderStore.shared

    @State private var selectedPresetID = ""
    @State private var name: String
    @State private var baseURL: String
    @State private var protocolKind: CustomProvider.ProtocolKind
    @State private var modelIDs: [String]
    @State private var supportsImages: Bool
    @State private var apiKey: String
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var showRemoveConfirm = false

    init(initialProvider: CustomProvider, onSaved: @escaping (CustomProvider) -> Void) {
        self.initialProvider = initialProvider
        self.onSaved = onSaved
        _name = State(initialValue: initialProvider.name)
        _baseURL = State(initialValue: initialProvider.baseURL)
        _protocolKind = State(initialValue: initialProvider.protocolKind)
        _modelIDs = State(initialValue: initialProvider.modelIDs)
        _supportsImages = State(initialValue: initialProvider.supportsImages)
        _apiKey = State(initialValue: APIKeyStore.shared.customKey(id: initialProvider.id))
    }

    private var isNewProvider: Bool {
        store.provider(id: initialProvider.id) == nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start from", selection: $selectedPresetID) {
                        Text("Custom URL").tag("")
                        ForEach(CustomProvider.presets) { preset in
                            Label(preset.name, systemImage: preset.systemImage).tag(preset.id)
                        }
                    }
                    .onChange(of: selectedPresetID) { _, id in
                        guard let preset = CustomProvider.presets.first(where: { $0.id == id }) else { return }
                        apply(preset: preset)
                    }
                    if let preset = CustomProvider.presets.first(where: { $0.id == selectedPresetID }) {
                        Text(preset.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Presets fill in the address for you — you only paste your key.")
                }

                Section {
                    TextField("Name (e.g. My Ollama)", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                    Picker("Protocol", selection: $protocolKind) {
                        ForEach(CustomProvider.ProtocolKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                } header: {
                    Text("Connection")
                }

                Section {
                    SecureField("API key (optional for local AI)", text: $apiKey)
                    Text("Stored securely in your Mac's Keychain. Local providers like Ollama don't need one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("API key")
                }

                Section {
                    ForEach(modelIDs.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("model-id", text: $modelIDs[index])
                                .autocorrectionDisabled()
                            Button {
                                modelIDs.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .disabled(modelIDs.count <= 1)
                        }
                    }
                    Button {
                        modelIDs.append("")
                    } label: {
                        Label("Add a model manually", systemImage: "plus.circle")
                    }

                    Button {
                        fetchModels()
                    } label: {
                        if isFetching {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Fetching…")
                            }
                        } else {
                            Label("Fetch model list", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isFetching || trimmedBaseURL.isEmpty)
                    .disabled(trimmedBaseURL.isEmpty)

                    if let fetchError {
                        Text(fetchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Accepts image attachments", isOn: $supportsImages)
                } header: {
                    Text("Models")
                } footer: {
                    Text("“Fetch model list” asks the provider which models it offers.")
                }

                if !isNewProvider {
                    Section {
                        Button("Remove this provider", role: .destructive) {
                            showRemoveConfirm = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNewProvider ? "Add Provider" : "Edit Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || trimmedBaseURL.isEmpty)
                }
            }
            .confirmationDialog(
                "Remove “\(trimmedName)”?",
                isPresented: $showRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    keyStore.removeCustomKey(id: initialProvider.id)
                    store.remove(id: initialProvider.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The provider and its saved key are removed. Your projects are not touched.")
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private func apply(preset: CustomProvider.Preset) {
        let nameMatchesAPreset = CustomProvider.presets.contains { $0.name == trimmedName }
        if trimmedName.isEmpty || nameMatchesAPreset {
            name = preset.name
        }
        baseURL = preset.baseURL
        protocolKind = preset.protocolKind
    }

    private func fetchModels() {
        var probe = initialProvider
        probe.baseURL = trimmedBaseURL
        probe.protocolKind = protocolKind
        isFetching = true
        fetchError = nil
        Task {
            do {
                let ids = try await CustomProviderModelFetcher.fetchModelIDs(for: probe, apiKey: apiKey)
                await MainActor.run {
                    isFetching = false
                    if ids.isEmpty {
                        fetchError = "The provider answered, but no models were listed. Add one manually."
                    } else {
                        mergeFetchedModelIDs(ids)
                    }
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    fetchError = error.localizedDescription
                }
            }
        }
    }

    private func mergeFetchedModelIDs(_ ids: [String]) {
        var seen = Set(modelIDs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        for id in ids where !seen.contains(id) {
            modelIDs.append(id)
            seen.insert(id)
        }
    }

    private func save() {
        var provider = initialProvider
        provider.name = trimmedName
        provider.baseURL = trimmedBaseURL
        provider.protocolKind = protocolKind
        provider.modelIDs = modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        provider.supportsImages = supportsImages

        if isNewProvider {
            store.add(provider)
        } else {
            store.update(provider)
        }
        keyStore.setCustomKey(apiKey, id: provider.id)
        onSaved(provider)
        dismiss()
    }
}

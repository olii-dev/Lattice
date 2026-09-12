import SwiftUI

/// Composite identity for `CapabilitySettingsView`'s refresh `.task(id:)`. Re-runs the refresh
/// when EITHER the chat-driven `refreshToken` changes (a capability tool call) OR the project
/// root changes (the user switched projects with the inspector open). Both paths clear local
/// undetectable state and re-query disk.
private struct RefreshKey: Hashable {
    let refreshToken: Int
    let projectPath: String
}

/// A section for browsing and toggling Apple capabilities.
///
/// Mirrors the same `CapabilityApplicator` engine as the chat tools (`add_capability` /
/// `remove_capability`), so changes made here and via chat stay in sync. The host bumps
/// `refreshToken` after a chat-driven capability change so this view re-reads status from disk.
struct CapabilitySettingsView: View {
    let projectRoot: URL
    /// Bumped by the host when a chat add_capability/remove_capability call completes,
    /// so this view refreshes its status from disk. Used with `.task(id:)`.
    var refreshToken: Int = 0

    @State private var status: CapabilityStatus = .init(activeCapabilities: [])
    @State private var errorText: String?
    @State private var inFlight = false

    /// Capability ids the user has applied through this UI that cannot be detected on disk
    /// (e.g. StoreKit, which has no entitlement key and no Info.plist key — only a framework).
    /// `CapabilityStatusChecker.check` never reports these, so without local tracking the toggle
    /// would snap back to off after a successful apply. Unioned into each toggle's `get` so they
    /// stay on once enabled here.
    ///
    /// Per-view-instance state: resets when the project switches (see `RefreshKey`) or when the
    /// view reconstructs. That's acceptable for v1 — detected capabilities always reflect real
    /// disk state; only the genuinely-undetectable ones lean on local intent.
    @State private var locallyAppliedUndetectable: Set<String> = []

    // Per-capability parameter inputs. Filled by the user before toggling on.
    @State private var appGroupInput: String = ""
    @State private var apsEnvironment: String = "development"
    @State private var keychainGroupInput: String = ""
    @State private var iCloudContainerInput: String = ""
    @State private var healthShareUsageInput: String = ""
    @State private var healthUpdateUsageInput: String = ""
    @State private var cameraUsageInput: String = ""
    @State private var backgroundModes: Set<String> = []

    /// The UIBackgroundModes values offered in the UI. Covers the common cases; the user can
    /// also type free-form via the chat tool for rarer modes.
    private let backgroundModeOptions: [(id: String, label: String)] = [
        ("audio", "Audio"),
        ("location", "Location updates"),
        ("voip", "VoIP"),
        ("external-accessory", "External accessory"),
        ("bluetooth-central", "Bluetooth central"),
        ("bluetooth-peripheral", "Bluetooth peripheral"),
        ("fetch", "Background fetch"),
        ("processing", "Background processing"),
        ("remote-notification", "Remote notification"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AppleCapabilityCatalog.all) { cap in
                capabilityRow(cap)
            }
            if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
                    .textSelection(.enabled)
            }
        }
        .task(id: RefreshKey(refreshToken: refreshToken, projectPath: projectRoot.path)) {
            // Clear local-only undetectable state on any refresh trigger. On a chat-driven
            // refresh the set is rebuilt by the user re-applying; on a project switch the old
            // project's local intent is meaningless for the new one.
            locallyAppliedUndetectable = []
            await refreshStatus()
        }
    }

    @ViewBuilder
    private func capabilityRow(_ cap: AppleCapability) -> some View {
        // Detected on disk OR locally applied-but-undetectable (e.g. StoreKit). Detected
        // capabilities always reflect real disk state; only undetectable ones lean on local intent.
        let isActive = status.activeCapabilities.contains(cap.id)
            || locallyAppliedUndetectable.contains(cap.id)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { isActive },
                set: { newValue in handleToggle(cap, isOn: newValue) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap.displayName).font(.body)
                    Text(cap.summary).font(.caption).foregroundStyle(.secondary)
                    if cap.id == "storekit" {
                        Text("StoreKit has no entitlement key, so this toggle can't read its state from disk — it tracks your local intent here. Real setup (App Store Connect products and the In-App Purchase capability in the Developer Portal) is manual.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            parameterFields(for: cap, isActive: isActive)

            if isActive, let notes = cap.provisioningNotes {
                DisclosureGroup("Manual steps") {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    /// Parameter inputs for capabilities that need user-supplied values. Shown always (not just
    /// when active) so the user can fill them before toggling on; the immediate-toggle UX applies
    /// with whatever is currently in the fields.
    @ViewBuilder
    private func parameterFields(for cap: AppleCapability, isActive: Bool) -> some View {
        switch cap.id {
        case "app_groups":
            VStack(alignment: .leading, spacing: 4) {
                Text("App Group identifiers (comma-separated)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("group.com.example.app", text: $appGroupInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        case "push_notifications":
            VStack(alignment: .leading, spacing: 4) {
                Text("APNs environment")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Picker("APNs environment", selection: $apsEnvironment) {
                    Text("Development").tag("development")
                    Text("Production").tag("production")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        case "keychain_sharing":
            VStack(alignment: .leading, spacing: 4) {
                Text("Keychain access group")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("$(AppIdentifierPrefix)com.example.shared", text: $keychainGroupInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        case "cloudkit_sync":
            VStack(alignment: .leading, spacing: 4) {
                Text("iCloud container identifiers (comma-separated, optional)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("iCloud.com.example.app", text: $iCloudContainerInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Text("Leave empty to use the default container.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case "healthkit":
            VStack(alignment: .leading, spacing: 4) {
                Text("Why the app reads health data")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("Shows your workout progress", text: $healthShareUsageInput)
                    .textFieldStyle(.roundedBorder)
                Text("Why the app writes health data")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("Saves workouts you log", text: $healthUpdateUsageInput)
                    .textFieldStyle(.roundedBorder)
            }
        case "ar":
            VStack(alignment: .leading, spacing: 4) {
                Text("Camera usage description")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("Shows the room so you can place objects", text: $cameraUsageInput)
                    .textFieldStyle(.roundedBorder)
                Text("Required. AR runs on a physical camera device, not the simulator.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case "background_modes":
            VStack(alignment: .leading, spacing: 4) {
                Text("Background modes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(backgroundModeOptions, id: \.id) { mode in
                        Toggle(mode.label, isOn: Binding(
                            get: { backgroundModes.contains(mode.id) },
                            set: { isOn in
                                if isOn { backgroundModes.insert(mode.id) }
                                else { backgroundModes.remove(mode.id) }
                            }
                        ))
                        .font(.caption)
                        .controlSize(.small)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func handleToggle(_ cap: AppleCapability, isOn: Bool) {
        if isOn {
            if let validationError = validationError(for: cap) {
                errorText = validationError
                return
            }
            errorText = nil
            let params = parameters(for: cap)
            Task { await applyCapability(cap, parameters: params) }
        } else {
            errorText = nil
            Task { await removeCapability(cap) }
        }
    }

    /// Returns an error string if the capability is being turned on without required parameters.
    private func validationError(for cap: AppleCapability) -> String? {
        switch cap.id {
        case "app_groups":
            let ids = parseAppGroupInput()
            if ids.isEmpty { return "Enter at least one App Group identifier before enabling App Groups." }
            return nil
        case "keychain_sharing":
            if keychainGroupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a keychain access group before enabling Keychain Sharing."
            }
            return nil
        case "background_modes":
            if backgroundModes.isEmpty {
                return "Select at least one background mode before enabling Background Modes."
            }
            return nil
        case "healthkit":
            if healthShareUsageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || healthUpdateUsageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter both health usage descriptions before enabling HealthKit — the App Store requires them."
            }
            return nil
        case "ar":
            if cameraUsageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a camera usage description before enabling AR — the App Store requires one."
            }
            return nil
        default:
            return nil
        }
    }

    private func parameters(for cap: AppleCapability) -> [String: Any] {
        switch cap.id {
        case "app_groups":
            return ["AppGroupIdentifier": parseAppGroupInput()]
        case "push_notifications":
            return ["APSEnvironment": apsEnvironment]
        case "keychain_sharing":
            return ["KeychainAccessGroup": keychainGroupInput.trimmingCharacters(in: .whitespacesAndNewlines)]
        case "background_modes":
            return ["UIBackgroundModes": Array(backgroundModes).sorted()]
        case "cloudkit_sync":
            let containers = iCloudContainerInput
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return containers.isEmpty ? [:] : ["iCloudContainerIdentifiers": containers]
        case "healthkit":
            return [
                "HealthShareUsageDescription": healthShareUsageInput.trimmingCharacters(in: .whitespacesAndNewlines),
                "HealthUpdateUsageDescription": healthUpdateUsageInput.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        case "ar":
            return ["CameraUsageDescription": cameraUsageInput.trimmingCharacters(in: .whitespacesAndNewlines)]
        default:
            return [:]
        }
    }

    private func parseAppGroupInput() -> [String] {
        appGroupInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func applyCapability(_ cap: AppleCapability, parameters: [String: Any]) async {
        guard !inFlight else { return }
        inFlight = true
        errorText = nil
        do {
            _ = try await CapabilityApplicator.apply(capabilityId: cap.id, to: projectRoot, parameters: parameters)
            // If the capability is undetectable on disk (no entitlement, no plist key — e.g.
            // StoreKit), record local intent so the toggle stays on after refreshStatus() runs.
            if cap.entitlements.isEmpty && cap.infoPlistKeys.isEmpty {
                locallyAppliedUndetectable.insert(cap.id)
            }
            await refreshStatus()
        } catch {
            errorText = error.localizedDescription
        }
        inFlight = false
    }

    private func removeCapability(_ cap: AppleCapability) async {
        guard !inFlight else { return }
        inFlight = true
        errorText = nil
        do {
            _ = try await CapabilityApplicator.remove(capabilityId: cap.id, from: projectRoot)
            // Drop local intent if present (only relevant for undetectable capabilities).
            locallyAppliedUndetectable.remove(cap.id)
            await refreshStatus()
        } catch {
            errorText = error.localizedDescription
        }
        inFlight = false
    }

    private func refreshStatus() async {
        do {
            status = try await CapabilityStatusChecker.check(projectRoot: projectRoot)
        } catch {
            // Treat unreadable status as "nothing active" rather than blanking the whole view
            // with an error — the per-toggle error path surfaces real failures.
            status = .init(activeCapabilities: [])
        }
    }
}

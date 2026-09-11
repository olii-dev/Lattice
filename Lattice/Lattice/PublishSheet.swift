import SwiftUI
import UniformTypeIdentifiers

/// Archive-and-upload sheet: App Store Connect API key setup on first use, then
/// one-click publish to TestFlight with a live log tail.
struct PublishToTestFlightSheet: View {
    let projectPath: String
    var defaultTeamID: String
    /// Called for every output line so the Console sheet keeps a full transcript.
    var onLogLine: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var credentials: TestFlightPublisher.Credentials?
    @State private var keyIDInput = ""
    @State private var issuerIDInput = ""

    @State private var schemes: [String] = []
    @State private var selectedScheme = ""
    @State private var destination: TestFlightPublisher.PublishDestination = .ios
    @State private var teamID = ""

    @State private var isRunning = false
    @State private var logTail: [String] = []
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private var canPublish: Bool {
        credentials != nil
            && !selectedScheme.isEmpty
            && !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
    }

    var body: some View {
        NavigationStack {
            Form {
                if credentials == nil {
                    apikeySetupSection
                } else {
                    publishSection
                }

                if !logTail.isEmpty {
                    Section("Log") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(logTail.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: 150)
                    }
                }

                if let resultMessage {
                    Section {
                        Label(resultMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Publish to TestFlight")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isRunning)
                }
            }
            .task { await initialLoad() }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Setup section

    private var apikeySetupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect App Store Connect")
                    .font(.subheadline.weight(.semibold))
                Text("Lattice needs an App Store Connect API key to upload builds. Create one at appstoreconnect.apple.com → Users and Access → Integrations (role: App Manager or Developer), download the .p8 file, then fill in its two identifiers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Key ID (e.g. ABC123XYZ)", text: $keyIDInput)
                .font(.caption.monospaced())
            TextField("Issuer ID (a UUID)", text: $issuerIDInput)
                .font(.caption.monospaced())

            Button {
                importKey()
            } label: {
                Label("Choose .p8 file…", systemImage: "key")
            }
            .disabled(keyIDInput.trimmingCharacters(in: .whitespaces).isEmpty
                      || issuerIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("API key")
        }
    }

    // MARK: - Publish section

    private var publishSection: some View {
        Section {
            Picker("Destination", selection: $destination) {
                ForEach(TestFlightPublisher.PublishDestination.allCases) { dest in
                    Text(dest.label).tag(dest)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)

            Picker("Scheme", selection: $selectedScheme) {
                if schemes.isEmpty {
                    Text("No schemes found").tag("")
                }
                ForEach(schemes, id: \.self) { scheme in
                    Text(scheme).tag(scheme)
                }
            }
            .pickerStyle(.menu)
            .disabled(isRunning)

            TextField("Team ID (10-character, from App Store Connect)", text: $teamID)
                .font(.caption.monospaced())
                .disabled(isRunning)

            Button {
                startPublish()
            } label: {
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Publishing…")
                    }
                } else {
                    Label("Archive & Upload", systemImage: "rocket")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPublish)
        } header: {
            Text("Build")
        } footer: {
            Text("Signing is automatic — the API key creates the profiles. The build lands in TestFlight; processing takes a few minutes.")
        }
    }

    // MARK: - Actions

    private func initialLoad() async {
        credentials = TestFlightPublisher.loadCredentials()
        if teamID.isEmpty {
            teamID = defaultTeamID
        }
        do {
            let target = try SimulatorBuildRunner.resolveXcodeTarget(projectRoot: URL(fileURLWithPath: projectPath))
            let found = try await SimulatorBuildRunner.listSchemes(target: target)
            schemes = found
            if selectedScheme.isEmpty {
                selectedScheme = found.first(where: { !$0.lowercased().contains("lattice") })
                    ?? found.first
                    ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose the App Store Connect API key (.p8)"
        panel.allowedContentTypes = [.data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TestFlightPublisher.storeKey(
                from: url,
                keyID: keyIDInput,
                issuerID: issuerIDInput
            )
            credentials = TestFlightPublisher.loadCredentials()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPublish() {
        guard let credentials else { return }
        isRunning = true
        resultMessage = nil
        errorMessage = nil
        logTail = []
        let root = projectPath
        let scheme = selectedScheme
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = destination
        Task {
            do {
                let summary = try await TestFlightPublisher.publish(
                    projectRoot: URL(fileURLWithPath: root),
                    scheme: scheme,
                    destination: dest,
                    teamID: team,
                    onLine: { line in
                        Task { @MainActor in
                            appendLog(line)
                        }
                    }
                )
                await MainActor.run {
                    isRunning = false
                    resultMessage = summary
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 40 {
            logTail.removeFirst(logTail.count - 40)
        }
        onLogLine(line)
    }
}

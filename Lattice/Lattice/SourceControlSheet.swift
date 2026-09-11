import SwiftUI

/// Commit / push / pull-request sheet backed by the git CLI. Auth for pushes
/// relies on the user's existing git credentials (macOS keychain helper).
struct SourceControlSheet: View {
    let projectPath: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var status = SourceControlService.Status(
        isRepository: false, branch: nil, hasUpstream: false,
        dirtyCount: 0, untrackedCount: 0, aheadCount: 0, behindCount: 0
    )
    @State private var commitMessage = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    private var totalChanges: Int { status.dirtyCount + status.untrackedCount }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if status.isRepository {
                    commitSection
                    pushSection
                } else {
                    initSection
                }
                if let message {
                    Section {
                        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(isError ? .orange : .green)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Source Control")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .task { refresh() }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            if status.isRepository {
                LabeledContent("Branch") {
                    if let branch = status.branch {
                        Text(branch).fontWeight(.semibold)
                    } else {
                        Text("Detached HEAD").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Changes") {
                    Text(totalChanges == 0 ? "Clean" : "\(totalChanges) changed")
                        .fontWeight(.semibold)
                }
                if status.hasUpstream, status.aheadCount > 0 || status.behindCount > 0 {
                    LabeledContent("Sync") {
                        Text("↑\(status.aheadCount) ↓\(status.behindCount)")
                            .font(.callout.monospacedDigit())
                    }
                }
            } else {
                LabeledContent("Repository") {
                    Text("Not set up").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text((projectPath as NSString).lastPathComponent)
        }
    }

    private var commitSection: some View {
        Section {
            TextField("Commit message (e.g. Add settings screen)", text: $commitMessage, axis: .vertical)
                .lineLimit(2...3)
                .disabled(isWorking)

            Button {
                run {
                    try SourceControlService.commit(projectRoot: URL(fileURLWithPath: projectPath), message: commitMessage)
                    commitMessage = ""
                    return "Committed \(totalChanges) file\(totalChanges == 1 ? "" : "s")."
                }
            } label: {
                Label(totalChanges == 0 ? "Nothing to commit" : "Commit all changes", systemImage: "checkmark.circle")
            }
            .disabled(isWorking || totalChanges == 0 || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Commit")
        } footer: {
            Text("Stages every changed and new file, then commits.")
        }
    }

    private var pushSection: some View {
        Section {
            Button {
                run {
                    try SourceControlService.push(projectRoot: URL(fileURLWithPath: projectPath))
                    return "Pushed to origin."
                }
            } label: {
                Label("Push to origin", systemImage: "arrow.up.circle")
            }
            .disabled(isWorking)

            if let compareURL = SourceControlService.pullRequestCompareURL(projectRoot: URL(fileURLWithPath: projectPath)) {
                Button {
                    openURL(compareURL)
                } label: {
                    Label("Open pull request on GitHub", systemImage: "arrow.triangle.pull")
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Remote")
        } footer: {
            Text("Pushes use your Mac's existing git credentials. To enable pull requests, add a GitHub remote named origin.")
        }
    }

    private var initSection: some View {
        Section {
            Button {
                run {
                    try SourceControlService.initializeRepository(projectRoot: URL(fileURLWithPath: projectPath))
                    return "Git repository initialized with an initial commit."
                }
            } label: {
                Label("Initialize Git Repository", systemImage: "plus.circle")
            }
            .disabled(isWorking)
        } footer: {
            Text("Git enables checkpoints and history restore in Lattice, and is required to push to GitHub.")
        }
    }

    // MARK: - Actions

    private func refresh() {
        status = SourceControlService.status(projectRoot: URL(fileURLWithPath: projectPath))
    }

    private func run(_ operation: () throws -> String) {
        isWorking = true
        message = nil
        let result: Result<String, Error>
        do {
            let text = try operation()
            result = .success(text)
        } catch {
            result = .failure(error)
        }
        isWorking = false
        switch result {
        case .success(let text):
            isError = false
            message = text
        case .failure(let error):
            isError = true
            message = error.localizedDescription
        }
        refresh()
    }
}

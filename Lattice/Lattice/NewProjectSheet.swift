import AppKit
import SwiftUI

struct NewProjectSheet: View {
    @Binding var isPresented: Bool
    var onCreated: (URL) -> Void

    @State private var platform: ProjectTemplatePlatform = .iOS
    @State private var productName = ""
    @State private var organizationId = "com.example"
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project")
                .font(.title2.weight(.semibold))

            Picker("Platform", selection: $platform) {
                ForEach(ProjectTemplatePlatform.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)

            TextField("Product name (letters and numbers)", text: $productName)
                .textFieldStyle(.roundedBorder)

            TextField("Organization identifier (e.g. com.mycompany)", text: $organizationId)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Choose location…") {
                    createProject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .scaleEffect(1.2)
            }
        }
    }

    private func createProject() {
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create here"
        panel.message = "Select the parent folder for the new project. A subfolder with the product name will be created."

        guard panel.runModal() == .OK, let parent = panel.url else { return }

        isWorking = true
        defer { isWorking = false }
        do {
            let root = try ProjectTemplateCopier.createProject(
                platform: platform,
                productName: productName,
                organizationIdentifier: organizationId,
                parentDirectory: parent
            )
            onCreated(root)
            isPresented = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

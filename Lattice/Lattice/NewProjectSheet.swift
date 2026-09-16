import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct NewProjectGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Create a project from bundled templates (with optional app icon).
struct NewProjectSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var isPresented: Bool
    var onCreated: (URL, ProjectTemplatePlatform) -> Void

    @State private var platform: ProjectTemplatePlatform = .iOS
    @State private var productName = ""
    @State private var isGame = false
    @State private var customAppIcon: NSImage?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            LatticeWindowBackdrop()
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.35)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        platformPicker
                        productField
                        gameSection
                        appIconSection
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(LatticeDesign.Spacing.xl)
                }
                Divider().opacity(0.35)
                footerBar
            }
            .frame(minWidth: 520, minHeight: 560)
            .background(
                RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.1), lineWidth: 1)
            )
            .padding(LatticeDesign.Spacing.xl)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 28, y: 14)

            if isWorking {
                ProgressView("Creating project…")
                    .padding(LatticeDesign.Spacing.xl)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LatticeDesign.Radius.panel, style: .continuous))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "plus.square.dashed")
                .font(.title.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: LatticeDesign.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("New project")
                    .font(.title2.weight(.bold))
                Text("Pick a platform, name your app, then choose where to save it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(LatticeDesign.Spacing.xl)
    }

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Platform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.8)
            HStack(spacing: 10) {
                ForEach(ProjectTemplatePlatform.allCases) { p in
                    platformCard(p)
                }
            }
        }
    }

    private func platformCard(_ p: ProjectTemplatePlatform) -> some View {
        let selected = platform == p
        return Button {
            platform = p
        } label: {
            VStack(spacing: 10) {
                Image(systemName: platformSymbol(p))
                    .font(.title2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(p.title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func platformSymbol(_ p: ProjectTemplatePlatform) -> String {
        switch p {
        case .iOS: return "iphone"
        case .macOS: return "laptopcomputer"
        case .watchOS: return "applewatch"
        }
    }

    private var productField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.8)
            TextField("MyApp", text: $productName)
                .textFieldStyle(.roundedBorder)
                .font(.body)
            Text("Letters and numbers only; becomes the Xcode target and folder name.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Bundle ID is chosen automatically (com.lattice.<your app name in lowercase>). You can change it later in Xcode or ask Lattice in chat.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var gameSection: some View {
        Toggle(isOn: $isGame) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This is a game")
                        .font(.body.weight(.medium))
                    Text("Switches Lattice into Game Mode — SpriteKit/RealityKit, game loop, physics, and game feel instead of app-style screens and forms. You can still pick the engine in chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 4)
    }

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App icon (optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.8)
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06))
                    if let customAppIcon {
                        Image(nsImage: customAppIcon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(LatticeDesign.Spacing.m)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(width: 100, height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: LatticeDesign.Radius.card, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("Square PNG or JPEG works best. We scale to 1024×1024 for the asset catalog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Choose image…") { chooseAppIconImage() }
                            .modifier(NewProjectGlassButtonModifier())
                        if customAppIcon != nil {
                            Button("Remove") {
                                customAppIcon = nil
                            }
                            .modifier(NewProjectGlassButtonModifier())
                        }
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .modifier(NewProjectGlassButtonModifier())
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Choose location…") {
                createProject()
            }
            .modifier(NewProjectGlassButtonModifier())
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }

    private func chooseAppIconImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.image]
        panel.message = "Choose an app icon image."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let img = NSImage(contentsOf: url) {
            customAppIcon = img
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
        panel.message = "Select the parent folder. A subfolder named after your app will be created."

        guard panel.runModal() == .OK, let parent = panel.url else { return }

        isWorking = true
        defer { isWorking = false }
        do {
            let root = try ProjectTemplateCopier.createProject(
                platform: platform,
                productName: productName,
                parentDirectory: parent,
                appIcon: customAppIcon,
                isGame: isGame
            )
            onCreated(root, platform)
            isPresented = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

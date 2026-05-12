import AppKit
import SwiftUI

/// Hub: welcome + open/new project; searchable recents on the trailing side.
struct ProjectHubView: View {
    @ObservedObject var recentStore: RecentProjectsStore
    @Binding var selectedProjectPath: String
    @Binding var showProjectHub: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var showNewProject = false

    private var filteredRecents: [RecentProject] {
        recentStore.filtered(search: search)
    }

    private var relativeTime: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 780
            ZStack {
                hubBackdrop
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Group {
                    if wide {
                        HStack(alignment: .center, spacing: 24) {
                            leadingColumn
                                .frame(width: min(460, geo.size.width * 0.46), alignment: .leading)
                            trailingColumn
                                .frame(width: min(360, geo.size.width * 0.38))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(maxWidth: 940, maxHeight: .infinity, alignment: .center)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                leadingColumn
                                trailingColumn
                            }
                            .padding(20)
                        }
                    }
                }
                .padding(wide ? 28 : 0)
            }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(isPresented: $showNewProject) { createdRoot in
                selectedProjectPath = createdRoot.path
                recentStore.add(path: createdRoot.path)
                showProjectHub = false
            }
        }
    }

    private var hubBackdrop: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.1),
                        Color.clear,
                        Color.teal.opacity(0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var leadingColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: "sparkle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Lattice")
                        .font(.title2.weight(.semibold))
                    Text("Pick a project folder to get started, then chat and run locally.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    chooseProjectFolder()
                } label: {
                    Label("Open project folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(HubGlassButtonModifier())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    showNewProject = true
                } label: {
                    Label("New project…", systemImage: "plus.square.dashed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(HubGlassButtonModifier())
                .controlSize(.large)

                Text("Choose a folder or a recent project to start chatting. The assistant checks Xcode and simulators on your first message for each project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.12),
                            Color.accentColor.opacity(0.25),
                            Color.primary.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
    }

    private var trailingColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent projects")
                .font(.headline)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            if filteredRecents.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Folders you open appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredRecents) { project in
                            Button {
                                selectedProjectPath = project.path
                                recentStore.add(path: project.path)
                                showProjectHub = false
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    ProjectFolderIconView(path: project.path)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.displayName)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(relativeTime.localizedString(for: project.lastOpened, relativeTo: .now))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(project.path)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from recents", role: .destructive) {
                                    recentStore.remove(project)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.1),
                            Color.accentColor.opacity(0.18),
                            Color.primary.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the folder that contains your .xcodeproj or .xcworkspace."
        if !selectedProjectPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedProjectPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            selectedProjectPath = url.path
            recentStore.add(path: url.path)
            showProjectHub = false
        }
    }
}

private struct HubGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

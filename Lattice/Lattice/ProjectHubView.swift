import AppKit
import SwiftUI

/// Full-window project hub: hero + actions + searchable recents.
struct ProjectHubView: View {
    @ObservedObject var recentStore: RecentProjectsStore
    @Binding var selectedProjectPath: String
    @Binding var showProjectHub: Bool

    @Environment(\.colorScheme) private var colorScheme
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
            let wide = geo.size.width > 820
            ZStack {
                LatticeWindowBackdrop()
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Group {
                    if wide {
                        wideHubLayout(maxWidth: min(980, geo.size.width - 48))
                    } else {
                        ScrollView {
                            compactHubLayout
                                .padding(.horizontal, 20)
                                .padding(.vertical, 24)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Layouts

    private func wideHubLayout(maxWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HubHeroColumn(
                welcomeMark: latticeWelcomeMark(size: 58),
                onOpenFolder: chooseProjectFolder,
                onNewProject: { showNewProject = true }
            )
            .padding(.leading, 32)
            .padding(.trailing, 22)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)

            HubColumnDivider()

            HubRecentsColumn(
                search: $search,
                filteredRecents: filteredRecents,
                relativeTime: relativeTime,
                onSelect: { project in
                    selectedProjectPath = project.path
                    recentStore.add(path: project.path)
                    showProjectHub = false
                },
                onTogglePinned: { recentStore.togglePinned($0) },
                onRemove: { recentStore.remove($0) }
            )
            .padding(.leading, 22)
            .padding(.trailing, 30)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: maxWidth, alignment: .center)
        .frame(maxHeight: min(620, 640))
        .background(HubShellBackground())
        .clipShape(RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous)
                .strokeBorder(HubMetrics.shellStroke(colorScheme: colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 40, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactHubLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubHeroColumn(
                welcomeMark: latticeWelcomeMark(size: 52),
                onOpenFolder: chooseProjectFolder,
                onNewProject: { showNewProject = true }
            )
            .padding(26)

            Rectangle()
                .fill(HubMetrics.hairlineFill(colorScheme: colorScheme))
                .frame(height: 1)
                .padding(.horizontal, 8)

            HubRecentsColumn(
                search: $search,
                filteredRecents: filteredRecents,
                relativeTime: relativeTime,
                onSelect: { project in
                    selectedProjectPath = project.path
                    recentStore.add(path: project.path)
                    showProjectHub = false
                },
                onTogglePinned: { recentStore.togglePinned($0) },
                onRemove: { recentStore.remove($0) }
            )
            .padding(22)
        }
        .background(HubShellBackground())
        .clipShape(RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous)
                .strokeBorder(HubMetrics.shellStroke(colorScheme: colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.1), radius: 32, y: 14)
    }

    // MARK: - Welcome mark

    /// App Store–style icons leave a large safe margin; zoom past it so the artwork fills the mark.
    private static let welcomeMarkIconZoom: CGFloat = 1.52

    private func latticeWelcomeMark(size: CGFloat) -> some View {
        let corner = size * 0.24
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let side = size * Self.welcomeMarkIconZoom
        return Group {
            if let icon = NSApp.applicationIconImage {
                ZStack {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: side, height: side)
                }
                .frame(width: size, height: size)
                .clipped()
                .clipShape(shape)
            } else {
                shape
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.system(size: size * 0.48, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    // MARK: - Folder picker

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

// MARK: - Metrics + shell (hub-specific)

private enum HubMetrics {
    static let shellRadius: CGFloat = 26

    static func shellStroke(colorScheme: ColorScheme) -> LinearGradient {
        let b: CGFloat = colorScheme == .dark ? 0.08 : 0.06
        return LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.55),
                Color.accentColor.opacity(0.22),
                Color.white.opacity(b),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func hairlineFill(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
}

private struct HubShellBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: HubMetrics.shellRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.04 : 0.65),
                            Color.white.opacity(colorScheme == .dark ? 0.02 : 0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

private struct HubColumnDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.5),
                        Color.accentColor.opacity(0.15),
                        Color.white.opacity(colorScheme == .dark ? 0.04 : 0.25),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
            .padding(.vertical, 20)
    }
}

// MARK: - Hero

private struct HubHeroColumn<Mark: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var welcomeMark: Mark
    var onOpenFolder: () -> Void
    var onNewProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                welcomeMark
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lattice")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Build native apps with taste.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
            }

            Spacer(minLength: 28)

            VStack(alignment: .leading, spacing: 12) {
                Button(action: onNewProject) {
                    Label("Build New App", systemImage: "plus.app")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HubPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

                Button(action: onOpenFolder) {
                    Label("Import Existing App", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HubSecondaryButtonStyle())
            }

            Spacer(minLength: 20)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 2)
                Text("Start with what you want to build. Lattice will inspect the project, shape the native app flow, edit files, build locally, and keep iterating against your setup.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - Recents

private struct HubRecentsColumn: View {
    @Binding var search: String
    var filteredRecents: [RecentProject]
    var relativeTime: RelativeDateTimeFormatter
    var onSelect: (RecentProject) -> Void
    var onTogglePinned: (RecentProject) -> Void
    var onRemove: (RecentProject) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recents")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(1.1)
                Spacer()
                Text("\(filteredRecents.count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)))
            }
            .padding(.bottom, 14)

            HubSearchField(text: $search, colorScheme: colorScheme)
                .padding(.bottom, 14)

            if filteredRecents.isEmpty {
                HubRecentsEmpty(searchNonEmpty: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredRecents) { project in
                            HubRecentRow(
                                project: project,
                                relativeLabel: relativeTime.localizedString(for: project.lastOpened, relativeTo: .now),
                                colorScheme: colorScheme,
                                onSelect: { onSelect(project) },
                                onTogglePinned: { onTogglePinned(project) },
                                onRemove: { onRemove(project) }
                            )
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

private struct HubSearchField: View {
    @Binding var text: String
    var colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter by name or path", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.1), lineWidth: 1)
        )
    }
}

private struct HubRecentRow: View {
    let project: RecentProject
    let relativeLabel: String
    var colorScheme: ColorScheme
    var onSelect: () -> Void
    var onTogglePinned: () -> Void
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 14) {
                ProjectFolderIconView(path: project.path)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 6) {
                            if project.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary.opacity(0.9))
                            }
                            Text(project.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(relativeLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(project.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    if isHovering {
                        Button(action: onTogglePinned) {
                            Image(systemName: project.isPinned ? "pin.slash" : "pin")
                                .font(.caption.weight(.semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(project.isPinned ? "Unpin" : "Pin to top")

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption.weight(.semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.16 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(project.isPinned ? "Unpin from top" : "Pin to top", action: onTogglePinned)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Button("Remove from recents", role: .destructive, action: onRemove)
        }
    }

    private var rowFill: Color {
        if isHovering {
            return Color.primary.opacity(colorScheme == .dark ? 0.115 : 0.07)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035)
    }
}

private struct HubRecentsEmpty: View {
    var searchNonEmpty: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
                    .frame(width: 56, height: 56)
                Image(systemName: searchNonEmpty ? "line.3.horizontal.decrease.circle" : "square.stack.3d.up")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            Text(searchNonEmpty ? "No matches" : "No recents yet")
                .font(.headline)
            Text(
                searchNonEmpty
                    ? "Try a shorter path fragment or the project display name."
                    : "Folders you open are saved here for quick access."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Button styles

private struct HubPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color.accentColor.opacity(0.35), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 2 : 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HubSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}

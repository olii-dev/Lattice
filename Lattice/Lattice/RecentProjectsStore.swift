import Combine
import Foundation
import SwiftUI

/// A recently opened project folder (iOS / Xcode workspace root).
struct RecentProject: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    var displayName: String
    var lastOpened: Date
    var isPinned: Bool
    /// Detected Apple platform (iOS / macOS / watchOS). nil until first detection.
    /// Stored so the hub can show a badge without re-reading the project on every render.
    var platform: RecentProjectPlatform?

    init(path: String, displayName: String? = nil, lastOpened: Date = .now, isPinned: Bool = false, platform: RecentProjectPlatform? = nil) {
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.lastOpened = lastOpened
        self.isPinned = isPinned
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case path, displayName, lastOpened, isPinned, platform
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? (path as NSString).lastPathComponent
        self.lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? .now
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        // Older saves predate the platform field; tolerate its absence.
        self.platform = try c.decodeIfPresent(RecentProjectPlatform.self, forKey: .platform)
    }
}

/// The Apple platform a recent project targets. Detected from the project's `SDKROOT`.
enum RecentProjectPlatform: String, Codable, CaseIterable {
    case iOS
    case macOS
    case watchOS

    /// SF Symbol used for the hub badge.
    var symbolName: String {
        switch self {
        case .iOS: return "iphone"
        case .macOS: return "macbook"
        case .watchOS: return "applewatch"
        }
    }

    /// Short label for tooltips / accessibility.
    var label: String { rawValue }

    /// Detect the platform from a `SDKROOT` build setting value.
    /// `iphoneos` → iOS, `macosx` → macOS, `watchos` → watchOS.
    init?(sdkRoot: String?) {
        guard let sdkRoot else { return nil }
        switch sdkRoot {
        case "iphoneos": self = .iOS
        case "macosx": self = .macOS
        case "watchos": self = .watchOS
        default: return nil
        }
    }
}

private let recentProjectsStorageKey = "recentProjectsJSON"
private let maxRecentProjects = 12

@MainActor
final class RecentProjectsStore: ObservableObject {
    @Published private(set) var projects: [RecentProject] = []

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsStorageKey),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
        else {
            projects = []
            return
        }
        projects = sortProjects(decoded)
        // Backfill platform for recents saved before the field existed.
        refreshMissingPlatforms()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsStorageKey)
    }

    func add(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = projects.first(where: { $0.path == trimmed })
        var list = projects.filter { $0.path != trimmed }
        let name = (trimmed as NSString).lastPathComponent
        list.insert(
            RecentProject(
                path: trimmed,
                displayName: name,
                lastOpened: .now,
                isPinned: existing?.isPinned ?? false,
                platform: existing?.platform ?? RecentProject.detectPlatform(path: trimmed)
            ),
            at: 0
        )
        if list.count > maxRecentProjects {
            list = Array(list.prefix(maxRecentProjects))
        }
        projects = sortProjects(list)
        persist()
    }

    /// Re-detect platforms for any recents that don't yet have one (e.g. migrated from an older
    /// save). Cheap and best-effort; failures just leave platform nil.
    func refreshMissingPlatforms() {
        var changed = false
        for i in projects.indices where projects[i].platform == nil {
            if let detected = RecentProject.detectPlatform(path: projects[i].path) {
                projects[i].platform = detected
                changed = true
            }
        }
        if changed { persist() }
    }

    func remove(_ project: RecentProject) {
        projects.removeAll { $0.path == project.path }
        persist()
    }

    func togglePinned(_ project: RecentProject) {
        guard let index = projects.firstIndex(where: { $0.path == project.path }) else { return }
        projects[index].isPinned.toggle()
        projects = sortProjects(projects)
        persist()
    }

    private func sortProjects(_ list: [RecentProject]) -> [RecentProject] {
        list.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastOpened > $1.lastOpened
        }
    }

    func filtered(search: String) -> [RecentProject] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter {
            $0.displayName.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }
}

extension RecentProject {
    /// Best-effort platform detection from a project folder. Reads the first `.xcodeproj`'s
    /// `project.pbxproj` and infers the platform from the app-target `SDKROOT` setting.
    /// Returns nil if no project or no recognizable SDKROOT is found.
    static func detectPlatform(path: String) -> RecentProjectPlatform? {
        let root = URL(fileURLWithPath: path)
        let projURL: URL
        if root.pathExtension == "xcodeproj" {
            projURL = root
        } else {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let first = contents.first(where: { $0.pathExtension == "xcodeproj" }) else {
                return nil
            }
            projURL = first
        }
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        guard let text = try? String(contentsOf: pbxPath, encoding: .utf8) else { return nil }
        // Find an application target's SDKROOT. The app-target SDKROOT sits inside an
        // XCBuildConfiguration block that also carries product-type application settings.
        // A simple, robust scan: the first `SDKROOT = <value>;` in the app-target configs.
        // App-target configs are the ones without `name = Debug;`/`name = Release;` at the
        // project level — but in practice SDKROOT is consistent across the app target, so we
        // take the first occurrence after the PBXNativeTarget application declaration.
        if let appRange = text.range(of: "productType = \"com.apple.product-type.application\";") {
            let after = text[appRange.upperBound...]
            if let sdkRange = after.range(of: "SDKROOT = ") {
                let tail = after[sdkRange.upperBound...]
                let value = tail.prefix(while: { $0 != ";" && $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
                return RecentProjectPlatform(sdkRoot: String(value))
            }
        }
        // Fallback: any SDKROOT in the file.
        if let sdkRange = text.range(of: "SDKROOT = ") {
            let tail = text[sdkRange.upperBound...]
            let value = tail.prefix(while: { $0 != ";" && $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            return RecentProjectPlatform(sdkRoot: String(value))
        }
        return nil
    }
}

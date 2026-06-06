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

    init(path: String, displayName: String? = nil, lastOpened: Date = .now, isPinned: Bool = false) {
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.lastOpened = lastOpened
        self.isPinned = isPinned
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
                isPinned: existing?.isPinned ?? false
            ),
            at: 0
        )
        if list.count > maxRecentProjects {
            list = Array(list.prefix(maxRecentProjects))
        }
        projects = sortProjects(list)
        persist()
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

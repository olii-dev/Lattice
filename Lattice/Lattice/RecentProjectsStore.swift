import Combine
import Foundation
import SwiftUI

/// A recently opened project folder (iOS / Xcode workspace root).
struct RecentProject: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    var displayName: String
    var lastOpened: Date

    init(path: String, displayName: String? = nil, lastOpened: Date = .now) {
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.lastOpened = lastOpened
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
        projects = decoded.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsStorageKey)
    }

    /// Insert or bump `path` to the top of recents.
    func add(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = projects.filter { $0.path != trimmed }
        let name = (trimmed as NSString).lastPathComponent
        list.insert(RecentProject(path: trimmed, displayName: name, lastOpened: .now), at: 0)
        if list.count > maxRecentProjects {
            list = Array(list.prefix(maxRecentProjects))
        }
        projects = list
        persist()
    }

    func remove(_ project: RecentProject) {
        projects.removeAll { $0.path == project.path }
        persist()
    }

    func filtered(search: String) -> [RecentProject] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter {
            $0.displayName.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }
}

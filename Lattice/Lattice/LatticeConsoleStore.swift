import Combine
import Foundation

struct LatticeConsoleSession: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var category: String
    var startedAt: String
    var lines: [String]
}

/// Per-project append-only log for the Console sheet (last ~200 lines each), persisted across launches.
@MainActor
final class LatticeConsoleStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var sessions: [LatticeConsoleSession] = []

    private var buckets: [String: [LatticeConsoleSession]] = [:]
    /// Fingerprint for `selectedProjectPath`; empty when no project.
    private var visibleKey: String = ""

    private let maxLinesPerProject = 200
    private let maxStoredCharactersPerProject = 120_000
    private let maxLineLength = 900
    private let maxSessionsPerProject = 18
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func storageKey(projectFingerprint: String) -> String {
        "latticeConsoleLinesV1.\(projectFingerprint)"
    }

    private func loadBucketFromDiskIfNeeded(projectFingerprint key: String) {
        guard !key.isEmpty else { return }
        if buckets[key] != nil { return }
        let udKey = Self.storageKey(projectFingerprint: key)
        guard let data = UserDefaults.standard.data(forKey: udKey) else { return }
        if let decodedSessions = try? JSONDecoder().decode([LatticeConsoleSession].self, from: data),
           !decodedSessions.isEmpty {
            buckets[key] = decodedSessions
            return
        }
        if let decodedLines = try? JSONDecoder().decode([String].self, from: data),
           !decodedLines.isEmpty {
            buckets[key] = [
                LatticeConsoleSession(
                    id: UUID(),
                    title: "Earlier log",
                    category: "legacy",
                    startedAt: formatter.string(from: Date()),
                    lines: decodedLines
                )
            ]
        }
    }

    private func persistBucket(projectFingerprint key: String) {
        guard !key.isEmpty else { return }
        let sessions = buckets[key] ?? []
        let udKey = Self.storageKey(projectFingerprint: key)
        if sessions.isEmpty {
            UserDefaults.standard.removeObject(forKey: udKey)
        } else if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    func setVisibleProject(path: String) {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = t.isEmpty ? "" : ChatSessionPersistence.projectStorageFingerprint(path: t)
        visibleKey = key
        loadBucketFromDiskIfNeeded(projectFingerprint: key)
        sessions = buckets[key] ?? []
        lines = sessions.last?.lines ?? []
    }

    func beginSession(title: String, category: String, projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        loadBucketFromDiskIfNeeded(projectFingerprint: key)
        var bucket = buckets[key] ?? []
        bucket.append(
            LatticeConsoleSession(
                id: UUID(),
                title: title,
                category: category,
                startedAt: formatter.string(from: Date()),
                lines: []
            )
        )
        if bucket.count > maxSessionsPerProject {
            bucket.removeFirst(bucket.count - maxSessionsPerProject)
        }
        buckets[key] = bucket
        persistBucket(projectFingerprint: key)
        if key == visibleKey {
            sessions = bucket
            lines = bucket.last?.lines ?? []
        }
    }

    func append(_ text: String, category: String, projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        loadBucketFromDiskIfNeeded(projectFingerprint: key)
        var bucket = buckets[key] ?? []
        ensureActiveSession(in: &bucket, category: category)
        let ts = formatter.string(from: Date())
        let prefix = "[\(ts)] [\(category)]"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            bucket[bucket.count - 1].lines.append("\(prefix) \(clampedLine(String(line)))")
        }
        trimBucket(&bucket[bucket.count - 1].lines)
        buckets[key] = bucket
        persistBucket(projectFingerprint: key)
        if key == visibleKey {
            sessions = bucket
            lines = bucket.last?.lines ?? []
        }
    }

    func appendLine(_ line: String, category: String, projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        loadBucketFromDiskIfNeeded(projectFingerprint: key)
        var bucket = buckets[key] ?? []
        ensureActiveSession(in: &bucket, category: category)
        let ts = formatter.string(from: Date())
        bucket[bucket.count - 1].lines.append("[\(ts)] [\(category)] \(clampedLine(line))")
        trimBucket(&bucket[bucket.count - 1].lines)
        buckets[key] = bucket
        persistBucket(projectFingerprint: key)
        if key == visibleKey {
            sessions = bucket
            lines = bucket.last?.lines ?? []
        }
    }

    func clear(projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        buckets[key] = []
        persistBucket(projectFingerprint: key)
        if key == visibleKey {
            sessions = []
            lines = []
        }
    }

    var fullText: String {
        lines.joined(separator: "\n")
    }

    private func trimBucket(_ bucket: inout [String]) {
        if bucket.count > maxLinesPerProject {
            bucket.removeFirst(bucket.count - maxLinesPerProject)
        }
        var totalCharacters = bucket.reduce(0) { $0 + $1.count }
        while totalCharacters > maxStoredCharactersPerProject, bucket.count > 1 {
            totalCharacters -= bucket.removeFirst().count
        }
    }

    private func clampedLine(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .newlines)
        guard text.count > maxLineLength else { return text }
        return String(text.prefix(maxLineLength - 1)) + "…"
    }

    private func ensureActiveSession(in bucket: inout [LatticeConsoleSession], category: String) {
        if bucket.isEmpty {
            bucket.append(
                LatticeConsoleSession(
                    id: UUID(),
                    title: defaultSessionTitle(for: category),
                    category: category,
                    startedAt: formatter.string(from: Date()),
                    lines: []
                )
            )
        }
    }

    private func defaultSessionTitle(for category: String) -> String {
        switch category {
        case "xcodebuild", "build":
            return "Local build"
        case "build-error":
            return "Build failure"
        default:
            return "Agent activity"
        }
    }
}

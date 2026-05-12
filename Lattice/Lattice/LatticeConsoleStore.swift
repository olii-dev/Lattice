import Combine
import Foundation

/// Per-project append-only log for the Console sheet (last ~200 lines each).
@MainActor
final class LatticeConsoleStore: ObservableObject {
    @Published private(set) var lines: [String] = []

    private var buckets: [String: [String]] = [:]
    /// Fingerprint for `selectedProjectPath`; empty when no project.
    private var visibleKey: String = ""

    private let maxLinesPerProject = 200
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func setVisibleProject(path: String) {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = t.isEmpty ? "" : ChatSessionPersistence.projectStorageFingerprint(path: t)
        visibleKey = key
        lines = buckets[key] ?? []
    }

    func append(_ text: String, category: String, projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        var bucket = buckets[key] ?? []
        let ts = formatter.string(from: Date())
        let prefix = "[\(ts)] [\(category)]"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            bucket.append("\(prefix) \(line)")
        }
        trimBucket(&bucket)
        buckets[key] = bucket
        if key == visibleKey {
            lines = bucket
        }
    }

    func appendLine(_ line: String, category: String, projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        var bucket = buckets[key] ?? []
        let ts = formatter.string(from: Date())
        bucket.append("[\(ts)] [\(category)] \(line)")
        trimBucket(&bucket)
        buckets[key] = bucket
        if key == visibleKey {
            lines = bucket
        }
    }

    func clear(projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = ChatSessionPersistence.projectStorageFingerprint(path: t)
        buckets[key] = []
        if key == visibleKey {
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
    }
}

import Foundation

/// One completed agent turn: transcript + API history + optional git working-tree snapshot (dangling stash OID or HEAD).
struct LatticeChatRestorePoint: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    /// First line of the user message that started this turn (for the history picker).
    let userLine: String
    /// Full user message text for this checkpoint (used to prefill the composer on restore).
    let userText: String?
    /// Git snapshot captured before the turn started, used to rewind that turn.
    let preTurnGitOID: String?
    /// Stable transcript anchor for the assistant turn this checkpoint belongs to.
    let assistantTurnAnchorId: UUID?
    /// From `git stash create --include-untracked` or `HEAD`; used with `reset --hard` + `clean -fd`.
    let gitTreeOID: String?
    let projectSummary: LatticeProjectSummary?
    let itemsPayload: Data
    let historyPayload: Data
}

/// Lightweight list row (mirrors `LatticeChatRestorePoint` without payloads).
struct LatticeChatRestorePointHeader: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let userLine: String
    let userText: String?
    let assistantTurnAnchorId: UUID?
    let canRewind: Bool
}

enum LatticeChatRestoreHistory {
    private static let keyPrefix = "latticeChatRestorePointsV1."
    private static let maxPoints = 32

    private static func storageKey(projectFingerprint: String) -> String {
        keyPrefix + projectFingerprint
    }

    private static func restorePointsDirectoryURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("Lattice", isDirectory: true)
            .appendingPathComponent("ChatRestorePoints", isDirectory: true)
    }

    private static func restorePointsFileURL(projectFingerprint: String) -> URL? {
        restorePointsDirectoryURL()?
            .appendingPathComponent("\(projectFingerprint).json", isDirectory: false)
    }

    static func loadAll(projectPath: String) -> [LatticeChatRestorePoint] {
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: projectPath)
        if let fileURL = restorePointsFileURL(projectFingerprint: fp),
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LatticeChatRestorePoint].self, from: data) {
            return decoded
        }

        // One-time migration from the older UserDefaults-backed restore history.
        if let data = UserDefaults.standard.data(forKey: storageKey(projectFingerprint: fp)),
           let decoded = try? JSONDecoder().decode([LatticeChatRestorePoint].self, from: data) {
            save(decoded, projectFingerprint: fp)
            UserDefaults.standard.removeObject(forKey: storageKey(projectFingerprint: fp))
            return decoded
        }

        return []
    }

    private static func save(_ points: [LatticeChatRestorePoint], projectFingerprint: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(projectFingerprint: projectFingerprint))

        guard let fileURL = restorePointsFileURL(projectFingerprint: projectFingerprint) else { return }
        if points.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let directoryURL = restorePointsDirectoryURL(),
              let data = try? JSONEncoder().encode(points) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Record state after a fully finished agent burst (transcript matches repo snapshot).
    static func appendCompletedTurn(
        projectPath: String,
        userLine: String,
        userText: String?,
        preTurnGitOID: String?,
        assistantTurnAnchorId: UUID?,
        gitTreeOID: String?,
        projectSummary: LatticeProjectSummary?,
        items: [ChatItem],
        conversationHistory: [[String: Any]]
    ) {
        let root = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        guard let itemsData = ChatSessionPersistence.encodeItemsSnapshot(items),
              let histData = ChatSessionPersistence.encodeHistorySnapshot(conversationHistory)
        else { return }

        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        var points = loadAll(projectPath: root)
        let trimmed = userLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "(empty message)" : String(trimmed.prefix(160))
        let oid = gitTreeOID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = LatticeChatRestorePoint(
            id: UUID(),
            createdAt: Date(),
            userLine: label,
            userText: userText?.trimmingCharacters(in: .whitespacesAndNewlines),
            preTurnGitOID: preTurnGitOID?.trimmingCharacters(in: .whitespacesAndNewlines),
            assistantTurnAnchorId: assistantTurnAnchorId,
            gitTreeOID: (oid?.isEmpty == false) ? oid : nil,
            projectSummary: projectSummary?.isEmpty == true ? nil : projectSummary,
            itemsPayload: itemsData,
            historyPayload: histData
        )
        points.append(point)
        if points.count > maxPoints {
            points = Array(points.suffix(maxPoints))
        }
        save(points, projectFingerprint: fp)
    }

    static func clear(projectPath: String) {
        let root = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        save([], projectFingerprint: fp)
        UserDefaults.standard.removeObject(forKey: storageKey(projectFingerprint: fp))
    }

    /// Keeps only points older than `pointId` (selected point and newer are removed).
    static func removeRestorePointAndNewer(projectPath: String, pointId: UUID) {
        let root = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        var points = loadAll(projectPath: root)
        guard let idx = points.firstIndex(where: { $0.id == pointId }) else { return }
        points = Array(points.prefix(upTo: idx))
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        save(points, projectFingerprint: fp)
    }

    static func decode(_ point: LatticeChatRestorePoint) -> (items: [ChatItem], history: [[String: Any]], projectSummary: LatticeProjectSummary?)? {
        guard let items = ChatSessionPersistence.decodeItemsSnapshot(point.itemsPayload),
              let history = ChatSessionPersistence.decodeHistorySnapshot(point.historyPayload)
        else { return nil }
        return (items, history, point.projectSummary)
    }
}

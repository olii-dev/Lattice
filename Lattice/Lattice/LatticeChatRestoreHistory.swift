import Foundation

/// One completed agent turn: transcript + API history + optional git working-tree snapshot (dangling stash OID or HEAD).
struct LatticeChatRestorePoint: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    /// First line of the user message that started this turn (for the history picker).
    let userLine: String
    /// Full user message text for this checkpoint (used to prefill the composer on restore).
    let userText: String?
    /// From `git stash create --include-untracked` or `HEAD`; used with `reset --hard` + `clean -fd`.
    let gitTreeOID: String?
    let itemsPayload: Data
    let historyPayload: Data
}

/// Lightweight list row (mirrors `LatticeChatRestorePoint` without payloads).
struct LatticeChatRestorePointHeader: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let userLine: String
    let userText: String?
}

enum LatticeChatRestoreHistory {
    private static let keyPrefix = "latticeChatRestorePointsV1."
    private static let maxPoints = 32

    private static func storageKey(projectFingerprint: String) -> String {
        keyPrefix + projectFingerprint
    }

    static func loadAll(projectPath: String) -> [LatticeChatRestorePoint] {
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: projectPath)
        guard let data = UserDefaults.standard.data(forKey: storageKey(projectFingerprint: fp)),
              let decoded = try? JSONDecoder().decode([LatticeChatRestorePoint].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ points: [LatticeChatRestorePoint], projectFingerprint: String) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(projectFingerprint: projectFingerprint))
    }

    /// Record state after a fully finished agent burst (transcript matches repo snapshot).
    static func appendCompletedTurn(
        projectPath: String,
        userLine: String,
        userText: String?,
        gitTreeOID: String?,
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
            gitTreeOID: (oid?.isEmpty == false) ? oid : nil,
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

    static func decode(_ point: LatticeChatRestorePoint) -> (items: [ChatItem], history: [[String: Any]])? {
        guard let items = ChatSessionPersistence.decodeItemsSnapshot(point.itemsPayload),
              let history = ChatSessionPersistence.decodeHistorySnapshot(point.historyPayload)
        else { return nil }
        return (items, history)
    }
}

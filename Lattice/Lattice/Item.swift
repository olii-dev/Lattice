import CryptoKit
import Foundation

// MARK: - Display model

struct ChatItem: Identifiable {
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    init(kind: Kind) {
        self.init(id: UUID(), kind: kind)
    }

    enum Kind {
        case user(String)
        case assistant(String, isStreaming: Bool)
        /// Provider “reasoning” / thinking stream (shown collapsed in transcript).
        case reasoning(String, isStreaming: Bool)
        case tool(name: String, input: String, output: String?, isError: Bool, isRunning: Bool)
        /// Transient: shown until first stream chunk; not persisted.
        case working
    }

    mutating func appendText(_ delta: String) {
        guard case .assistant(let text, _) = kind else { return }
        kind = .assistant(text + delta, isStreaming: true)
    }

    mutating func finalizeText() {
        guard case .assistant(let text, _) = kind else { return }
        kind = .assistant(text, isStreaming: false)
    }

    mutating func appendReasoning(_ delta: String) {
        guard case .reasoning(let text, _) = kind else { return }
        kind = .reasoning(text + delta, isStreaming: true)
    }

    mutating func finalizeReasoning() {
        guard case .reasoning(let text, _) = kind else { return }
        kind = .reasoning(text, isStreaming: false)
    }

    mutating func setToolInput(_ input: String) {
        guard case .tool(let name, _, let out, let err, _) = kind else { return }
        kind = .tool(name: name, input: input, output: out, isError: err, isRunning: true)
    }

    mutating func setToolResult(_ output: String, isError: Bool) {
        guard case .tool(let name, let input, _, _, _) = kind else { return }
        kind = .tool(name: name, input: input, output: output, isError: isError, isRunning: false)
    }
}

// MARK: - Session persistence (transcript)

private struct PersistedChatItem: Codable {
    enum Kind: String, Codable { case user, assistant, reasoning, tool }

    let id: UUID
    let kind: Kind
    let userText: String?
    let assistantText: String?
    let reasoningText: String?
    let toolName: String?
    let toolInput: String?
    let toolOutput: String?
    let toolIsError: Bool?

    init(chatItem: ChatItem) {
        self.id = chatItem.id
        switch chatItem.kind {
        case .user(let text):
            kind = .user
            userText = text
            assistantText = nil
            reasoningText = nil
            toolName = nil
            toolInput = nil
            toolOutput = nil
            toolIsError = nil
        case .assistant(let text, _):
            kind = .assistant
            userText = nil
            assistantText = text
            reasoningText = nil
            toolName = nil
            toolInput = nil
            toolOutput = nil
            toolIsError = nil
        case .reasoning(let text, _):
            kind = .reasoning
            userText = nil
            assistantText = nil
            reasoningText = text
            toolName = nil
            toolInput = nil
            toolOutput = nil
            toolIsError = nil
        case .tool(let name, let input, let output, let isError, _):
            kind = .tool
            userText = nil
            assistantText = nil
            reasoningText = nil
            toolName = name
            toolInput = input
            toolOutput = output
            toolIsError = isError
        case .working:
            fatalError("PersistedChatItem does not encode .working")
        }
    }

    func toChatItem() -> ChatItem {
        switch kind {
        case .user:
            return ChatItem(id: id, kind: .user(userText ?? ""))
        case .assistant:
            return ChatItem(id: id, kind: .assistant(assistantText ?? "", isStreaming: false))
        case .reasoning:
            return ChatItem(id: id, kind: .reasoning(reasoningText ?? "", isStreaming: false))
        case .tool:
            return ChatItem(
                id: id,
                kind: .tool(
                    name: toolName ?? "",
                    input: toolInput ?? "",
                    output: toolOutput,
                    isError: toolIsError ?? false,
                    isRunning: false
                )
            )
        }
    }
}

enum ChatSessionPersistence {
    /// Legacy global keys (single chat for all projects).
    private static let legacyItemsKey = "latticeSessionChatItemsV1"
    private static let legacyHistoryKey = "latticeSessionConversationHistoryV1"

    private static func normalizedPath(_ path: String) -> String {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "__no_project__" }
        return URL(fileURLWithPath: (t as NSString).standardizingPath).path
    }

    private static func fingerprint(for path: String) -> String {
        let norm = normalizedPath(path)
        let digest = SHA256.hash(data: Data(norm.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Stable per-project key (e.g. console buckets, feature flags) matching transcript storage.
    static func projectStorageFingerprint(path: String) -> String {
        fingerprint(for: path)
    }

    /// Same path normalization as storage keys: empty input yields empty string (not `__no_project__`).
    static func canonicalProjectPath(_ path: String) -> String {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return URL(fileURLWithPath: (t as NSString).standardizingPath).path
    }

    private static func itemsKey(forProjectPath path: String) -> String {
        "latticeSessionChatItemsV2.\(fingerprint(for: path))"
    }

    private static func historyKey(forProjectPath path: String) -> String {
        "latticeSessionConversationHistoryV2.\(fingerprint(for: path))"
    }

    private static func summaryKey(forProjectPath path: String) -> String {
        "latticeProjectSummaryV1.\(fingerprint(for: path))"
    }

    static func loadItems(projectPath: String) -> [ChatItem] {
        let key = itemsKey(forProjectPath: projectPath)
        if let data = UserDefaults.standard.data(forKey: key),
           let rows = try? JSONDecoder().decode([PersistedChatItem].self, from: data) {
            return rows.map { $0.toChatItem() }
        }
        // One-time migration: move legacy global transcript into this project's bucket.
        if let legacyData = UserDefaults.standard.data(forKey: legacyItemsKey),
           let rows = try? JSONDecoder().decode([PersistedChatItem].self, from: legacyData),
           !rows.isEmpty {
            UserDefaults.standard.set(legacyData, forKey: key)
            UserDefaults.standard.removeObject(forKey: legacyItemsKey)
            return rows.map { $0.toChatItem() }
        }
        return []
    }

    static func saveItems(_ items: [ChatItem], projectPath: String) {
        let rows = items.compactMap { item -> PersistedChatItem? in
            if case .working = item.kind { return nil }
            return PersistedChatItem(chatItem: item)
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: itemsKey(forProjectPath: projectPath))
    }

    static func loadHistory(projectPath: String) -> [[String: Any]] {
        let key = historyKey(forProjectPath: projectPath)
        if let data = UserDefaults.standard.data(forKey: key),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let arr = obj as? [[String: Any]] {
            return arr
        }
        if let legacyData = UserDefaults.standard.data(forKey: legacyHistoryKey),
           let obj = try? JSONSerialization.jsonObject(with: legacyData),
           let arr = obj as? [[String: Any]],
           !arr.isEmpty {
            UserDefaults.standard.set(legacyData, forKey: key)
            UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
            return arr
        }
        return []
    }

    static func saveHistory(_ history: [[String: Any]], projectPath: String) {
        guard JSONSerialization.isValidJSONObject(history),
              let data = try? JSONSerialization.data(withJSONObject: history)
        else { return }
        UserDefaults.standard.set(data, forKey: historyKey(forProjectPath: projectPath))
    }

    static func loadProjectSummary(projectPath: String) -> LatticeProjectSummary? {
        let key = summaryKey(forProjectPath: projectPath)
        guard let data = UserDefaults.standard.data(forKey: key),
              let summary = try? JSONDecoder().decode(LatticeProjectSummary.self, from: data),
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    static func saveProjectSummary(_ summary: LatticeProjectSummary?, projectPath: String) {
        let key = summaryKey(forProjectPath: projectPath)
        guard let summary, !summary.isEmpty,
              let data = try? JSONEncoder().encode(summary) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear(projectPath: String) {
        UserDefaults.standard.removeObject(forKey: itemsKey(forProjectPath: projectPath))
        UserDefaults.standard.removeObject(forKey: historyKey(forProjectPath: projectPath))
        UserDefaults.standard.removeObject(forKey: summaryKey(forProjectPath: projectPath))
    }

    // MARK: - Snapshots (chat history restore)

    /// Encodes persistable chat rows (same shape as `saveItems`, without `.working`).
    static func encodeItemsSnapshot(_ items: [ChatItem]) -> Data? {
        let rows = items.compactMap { item -> PersistedChatItem? in
            if case .working = item.kind { return nil }
            return PersistedChatItem(chatItem: item)
        }
        return try? JSONEncoder().encode(rows)
    }

    static func decodeItemsSnapshot(_ data: Data) -> [ChatItem]? {
        guard let rows = try? JSONDecoder().decode([PersistedChatItem].self, from: data) else { return nil }
        return rows.map { $0.toChatItem() }
    }

    static func encodeHistorySnapshot(_ history: [[String: Any]]) -> Data? {
        guard JSONSerialization.isValidJSONObject(history),
              let data = try? JSONSerialization.data(withJSONObject: history)
        else { return nil }
        return data
    }

    static func decodeHistorySnapshot(_ data: Data) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let arr = obj as? [[String: Any]]
        else { return nil }
        return arr
    }

    private static func environmentIntroKey(forProjectPath path: String) -> String {
        "latticeEnvIntroV1.\(fingerprint(for: path))"
    }

    /// One-time LLM environment audit per project folder (not cleared with chat).
    static func didCompleteEnvironmentIntro(projectPath: String) -> Bool {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        return UserDefaults.standard.bool(forKey: environmentIntroKey(forProjectPath: t))
    }

    static func markEnvironmentIntroCompleted(projectPath: String) {
        let t = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: environmentIntroKey(forProjectPath: t))
    }
}

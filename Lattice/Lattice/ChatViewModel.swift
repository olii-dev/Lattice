import AppKit
import Combine
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chat view model

/// Shown under a failed assistant bubble; retry truncates transcript + API history and reapplies `write_file` undos.
struct PendingRetryState: Equatable {
    let errorItemId: UUID
    let keepItemsPrefixCount: Int
    let keepHistoryPrefixCount: Int
    let fileUndos: [LatticeWriteFileUndo]
    /// `git rev-parse HEAD` at first tool execution in this burst (nil if not a git repo).
    let gitHeadOID: String?
    let gitProjectRoot: String?
    let resumeFromLastStableStep: Bool
}

/// A `write_file` change awaiting user review. The diff between `oldContent` and
/// `newContent` is rendered in the approval card.
struct PendingFileApproval: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let oldContent: String
    let newContent: String

    var fileName: String { (path as NSString).lastPathComponent }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    /// Bumped only when the transcript should pin to the bottom (streaming, tools, send). Not used for unrelated layout.
    @Published private(set) var transcriptScrollToBottomToken: UInt = 0
    /// Bumped when an `add_capability`/`remove_capability` tool call completes, so the
    /// Capabilities inspector re-reads real project state from disk.
    @Published var capabilityRefreshToken: Int = 0
    /// Parsed from the latest finalized assistant reply (Bundle / Team / version lines).
    @Published private(set) var pendingInspectorHints: AssistantInspectorHints?
    @Published private(set) var projectSummary: LatticeProjectSummary?
    @Published private(set) var livePhase: LatticeDirectorPhase?

    private let service = LLMService()
    private var executor: ToolExecutor {
        ToolExecutor(
            projectRootPath: scopedProjectPath.isEmpty ? nil : scopedProjectPath,
            simulatorUDID: toolSimulatorUDID,
            appBundleID: toolAppBundleID
        )
    }
    /// Selected simulator for `simulator_use`; set by the view alongside run-target changes.
    private var toolSimulatorUDID: String?
    /// The project app's bundle ID (default launch target for `simulator_use`).
    private var toolAppBundleID: String?
    private weak var consoleStore: LatticeConsoleStore?
    private var conversationHistory: [[String: Any]] = []
    private var agentTask: Task<Void, Never>?
    /// Transcript rows to keep when retrying the current user turn (prefix of `items` after the user bubble).
    private var burstKeepItemsPrefixCount: Int = 0
    /// API messages to keep when retrying (includes the user message for this turn).
    private var burstKeepHistoryPrefixCount: Int = 0
    private var burstFileUndos: [LatticeWriteFileUndo] = []
    /// First `HEAD` OID captured before any tool runs in this user burst (git rollback).
    private var burstGitStartOID: String?
    /// Matches `selectedProjectPath` from the main window (trimmed); drives per-project persistence.
    private var scopedProjectPath: String = ""
    private var compactionRunForThisAgentBurst = false
    /// Local-only compaction when estimated API history + system/tools is truly near the limit.
    private let compactionFillThreshold = 0.92
    private let compactionMinHistoryMessages = 14
    /// Keep this many recent API messages verbatim when trimming older history.
    private let compactionVerbatimTailMessages = 10
    /// Coalesces scroll/layout pulses while SSE text arrives (was one per token).
    private var lastTranscriptScrollPulse: Date = .distantPast
    private let transcriptScrollMinInterval: TimeInterval = 0.09

    @Published private(set) var pendingRetry: PendingRetryState?
    /// A `write_file` change awaiting user review; non-nil pauses the agent loop.
    @Published private(set) var pendingFileApproval: PendingFileApproval?
    /// Token usage reported by the provider for the most recent completed turn.
    @Published private(set) var lastTurnUsage: LLMTokenUsage?
    /// Completed-turn restore points (newest at end); headers only for UI.
    @Published private(set) var chatRestorePointHeaders: [LatticeChatRestorePointHeader] = []

    init(consoleStore: LatticeConsoleStore? = nil) {
        self.consoleStore = consoleStore
    }

    func reloadChatRestorePointHeaders() {
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            chatRestorePointHeaders = []
            return
        }
        let points = LatticeChatRestoreHistory.loadAll(projectPath: root)
        chatRestorePointHeaders = points.enumerated().map { index, point in
            let hasRestoreRevision = nonEmptyTrimmed(point.preTurnGitOID) != nil
                || (index > 0 && nonEmptyTrimmed(points[index - 1].gitTreeOID) != nil)
            return LatticeChatRestorePointHeader(
                id: point.id,
                createdAt: point.createdAt,
                userLine: point.userLine,
                userText: point.userText,
                assistantTurnAnchorId: point.assistantTurnAnchorId,
                canRewind: point.assistantTurnAnchorId != nil && hasRestoreRevision
            )
        }
    }

    /// Restores git to the selected checkpoint. Chat can restore to a different checkpoint (e.g. previous)
    /// so the selected turn can be removed from visible transcript while still restoring code correctly.
    func restoreHistory(selectedPointId: UUID, chatPointId: UUID?) {
        guard !isRunning else { return }
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let points = LatticeChatRestoreHistory.loadAll(projectPath: root)
        guard let selectedPoint = points.first(where: { $0.id == selectedPointId }) else { return }

        if let oid = selectedPoint.gitTreeOID, !oid.isEmpty {
            let result = LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: oid)
            guard result.isSuccess else {
                reportGitRestoreFailure(result, operation: "history checkpoint")
                return
            }
            let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
            LatticeGitWorkspaceCheckpoint.persistRetryBaseline(projectFingerprint: fp, oid: oid)
        }

        if let chatPointId,
           let chatPoint = points.first(where: { $0.id == chatPointId }),
           let decoded = LatticeChatRestoreHistory.decode(chatPoint) {
            items = decoded.items
            conversationHistory = decoded.history
            projectSummary = decoded.projectSummary
        } else if let decodedSelected = LatticeChatRestoreHistory.decode(selectedPoint) {
            // Never blank the whole transcript on restore fallback; prefer selected checkpoint snapshot.
            items = decodedSelected.items
            conversationHistory = decodedSelected.history
            projectSummary = decodedSelected.projectSummary
        }
        pendingRetry = nil
        clearPendingInspectorHints()
        burstFileUndos.removeAll()
        burstKeepItemsPrefixCount = items.count
        burstKeepHistoryPrefixCount = conversationHistory.count
        refreshBurstGitStartFromBaseline()
        LatticeChatRestoreHistory.removeRestorePointAndNewer(projectPath: root, pointId: selectedPointId)
        reloadChatRestorePointHeaders()
        persistSession()
    }

    func rewindCompletedTurn(checkpointId: UUID) {
        guard !isRunning else { return }
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let points = LatticeChatRestoreHistory.loadAll(projectPath: root)
        guard let selectedIndex = points.firstIndex(where: { $0.id == checkpointId }) else { return }

        let selectedPoint = points[selectedIndex]
        let previousPoint = selectedIndex > 0 ? points[selectedIndex - 1] : nil

        guard let restoreRevision = nonEmptyTrimmed(selectedPoint.preTurnGitOID)
            ?? nonEmptyTrimmed(previousPoint?.gitTreeOID) else {
            return
        }

        let rewindResult = LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: restoreRevision)
        guard rewindResult.isSuccess else {
            reportGitRestoreFailure(rewindResult, operation: "turn rewind")
            return
        }
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        LatticeGitWorkspaceCheckpoint.persistRetryBaseline(projectFingerprint: fp, oid: restoreRevision)

        if let previousPoint, let decoded = LatticeChatRestoreHistory.decode(previousPoint) {
            items = decoded.items
            conversationHistory = decoded.history
            projectSummary = decoded.projectSummary
        } else {
            items = []
            conversationHistory = []
            projectSummary = nil
        }

        pendingRetry = nil
        clearPendingInspectorHints()
        burstFileUndos.removeAll()
        burstKeepItemsPrefixCount = items.count
        burstKeepHistoryPrefixCount = conversationHistory.count
        refreshBurstGitStartFromBaseline()
        LatticeChatRestoreHistory.removeRestorePointAndNewer(projectPath: root, pointId: checkpointId)
        reloadChatRestorePointHeaders()
        persistSession()
    }

    /// Call when the selected project folder changes so each project keeps its own transcript + agent history.
    func syncProjectPath(_ rawPath: String) {
        let path = ChatSessionPersistence.canonicalProjectPath(rawPath)
        guard path != scopedProjectPath else { return }

        if isRunning {
            agentTask?.cancel()
            agentTask = nil
            isRunning = false
        }
        // A suspended write approval would otherwise leak its continuation.
        if pendingFileApproval != nil || writeApprovalContinuation != nil {
            pendingFileApproval = nil
            writeApprovalContinuation?.resume(returning: false)
            writeApprovalContinuation = nil
        }

        pendingRetry = nil
        if !items.isEmpty || !conversationHistory.isEmpty {
            persistSession()
        }

        scopedProjectPath = path
        items = ChatSessionPersistence.loadItems(projectPath: path)
        conversationHistory = ChatSessionPersistence.loadHistory(projectPath: path)
        projectSummary = ChatSessionPersistence.loadProjectSummary(projectPath: path)
        pendingRetry = nil
        livePhase = nil
        burstFileUndos.removeAll()
        burstGitStartOID = nil
        burstKeepItemsPrefixCount = items.count
        burstKeepHistoryPrefixCount = conversationHistory.count
        reloadChatRestorePointHeaders()
    }

    func persistSession() {
        ChatSessionPersistence.saveItems(items, projectPath: scopedProjectPath)
        ChatSessionPersistence.saveHistory(conversationHistory, projectPath: scopedProjectPath)
        ChatSessionPersistence.saveProjectSummary(projectSummary, projectPath: scopedProjectPath)
    }

    func clearPendingInspectorHints() {
        pendingInspectorHints = nil
    }

    private func requestTranscriptScrollToBottom(immediate: Bool) {
        if !immediate {
            let now = Date()
            guard now.timeIntervalSince(lastTranscriptScrollPulse) >= transcriptScrollMinInterval else { return }
            lastTranscriptScrollPulse = now
        }
        transcriptScrollToBottomToken &+= 1
    }

    /// Throttled scroll request for the streaming hot path. During SSE streaming the scroll fires
    /// on every chunk (dozens/sec); an unthrottled scroll-to-bottom on every token is a major
    /// source of UI jank. This coalesces to at most one scroll per `transcriptScrollMinInterval`.
    private func requestTranscriptScrollToBottomThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastTranscriptScrollPulse) >= transcriptScrollMinInterval else { return }
        lastTranscriptScrollPulse = now
        transcriptScrollToBottomToken &+= 1
    }

    private func noteTranscriptScrollIntent() {
        requestTranscriptScrollToBottom(immediate: false)
    }

    // MARK: - Write approval (diff review)

    /// When true (default), model `write_file` calls pause for user review first.
    static let writeApprovalDefaultsKey = "latticeRequireWriteApproval"

    static var writeApprovalRequired: Bool {
        UserDefaults.standard.object(forKey: writeApprovalDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: writeApprovalDefaultsKey)
    }

    private var writeApprovalContinuation: CheckedContinuation<Bool, Never>?

    /// Suspends the agent loop until the user approves or rejects the pending diff.
    private func requestWriteApproval(_ approval: PendingFileApproval) async -> Bool {
        pendingFileApproval = approval
        requestTranscriptScrollToBottom(immediate: true)
        let approved = await withCheckedContinuation { continuation in
            writeApprovalContinuation = continuation
        }
        pendingFileApproval = nil
        writeApprovalContinuation = nil
        return approved
    }

    /// Called by the approval card. Resumes the paused agent loop.
    func resolveWriteApproval(_ approved: Bool) {
        writeApprovalContinuation?.resume(returning: approved)
        writeApprovalContinuation = nil
        pendingFileApproval = nil
    }

    private func appendAssistantFailure(_ message: String) {
        let hadStableProgress = items.count > burstKeepItemsPrefixCount || conversationHistory.count > burstKeepHistoryPrefixCount
        let row = ChatItem(kind: .assistant(message, isStreaming: false))
        items.append(row)
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingRetry = PendingRetryState(
            errorItemId: row.id,
            keepItemsPrefixCount: max(0, burstKeepItemsPrefixCount),
            keepHistoryPrefixCount: max(0, burstKeepHistoryPrefixCount),
            fileUndos: burstFileUndos,
            gitHeadOID: burstGitStartOID,
            gitProjectRoot: root.isEmpty ? nil : root,
            resumeFromLastStableStep: hadStableProgress
        )
        requestTranscriptScrollToBottom(immediate: true)
    }

    /// Logs a failed git restore to the Console sheet and surfaces it inline in the transcript
    /// without touching retry state.
    private func reportGitRestoreFailure(_ result: LatticeGitWorkspaceCheckpoint.RestoreResult, operation: String) {
        guard let detail = result.failureDetail else { return }
        consoleStore?.appendLine(
            "Git restore failed (\(operation)): \(detail)",
            category: "build-error",
            projectPath: scopedProjectPath
        )
        items.append(ChatItem(kind: .assistant(
            "⚠️ Could not restore the workspace (\(operation)).\n\n\(detail)",
            isStreaming: false
        )))
        requestTranscriptScrollToBottom(immediate: true)
    }

    private func refreshBurstGitStartFromBaseline() {
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            burstGitStartOID = nil
            return
        }
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        burstGitStartOID = LatticeGitWorkspaceCheckpoint.loadRetryBaseline(projectFingerprint: fp)
            ?? LatticeGitWorkspaceCheckpoint.captureWorkingTreeSnapshot(worktree: root)
            ?? LatticeGitWorkspaceCheckpoint.captureHead(worktree: root)
    }

    private func persistGitBaselineAfterQuietTurnCompletion() -> String? {
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
        guard let snap = LatticeGitWorkspaceCheckpoint.captureWorkingTreeSnapshot(worktree: root) else { return nil }
        LatticeGitWorkspaceCheckpoint.persistRetryBaseline(projectFingerprint: fp, oid: snap)
        return snap
    }

    /// Re-runs the model from the last user message after git + file rollback for that attempt.
    func performRetry(apiKey: String, context: ChatContext) {
        guard let pack = pendingRetry, !isRunning, !apiKey.isEmpty else { return }
        if pack.resumeFromLastStableStep {
            items.removeAll { $0.id == pack.errorItemId }
            pendingRetry = nil
            burstKeepItemsPrefixCount = items.count
            burstKeepHistoryPrefixCount = conversationHistory.count
            burstFileUndos = pack.fileUndos
            burstGitStartOID = pack.gitHeadOID
            conversationHistory.append([
                "role": "user",
                "content": """
                [Retry request]
                The last attempt failed because of a provider or connection issue.
                Resume from the last completed step using the current workspace state.
                Do not restart from scratch or repeat already successful work unless it is required.
                """
            ])
            persistSession()
            isRunning = true
            livePhase = .build
            lastTurnUsage = nil
            requestTranscriptScrollToBottom(immediate: true)
            compactionRunForThisAgentBurst = false
            agentTask = Task {
                defer {
                    isRunning = false
                    livePhase = nil
                }
                await agenticLoop(apiKey: apiKey, context: context)
            }
            return
        }
        if let root = pack.gitProjectRoot, let oid = pack.gitHeadOID, !root.isEmpty, !oid.isEmpty {
            let result = LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: oid)
            guard result.isSuccess else {
                reportGitRestoreFailure(result, operation: "retry rollback")
                return
            }
        }
        for u in pack.fileUndos.reversed() {
            u.apply()
        }
        if items.count > pack.keepItemsPrefixCount {
            items = Array(items.prefix(pack.keepItemsPrefixCount))
        }
        if conversationHistory.count > pack.keepHistoryPrefixCount {
            conversationHistory = Array(conversationHistory.prefix(pack.keepHistoryPrefixCount))
        }
        pendingRetry = nil
        burstKeepItemsPrefixCount = pack.keepItemsPrefixCount
        burstKeepHistoryPrefixCount = pack.keepHistoryPrefixCount
        burstFileUndos.removeAll()
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            burstGitStartOID = LatticeGitWorkspaceCheckpoint.captureWorkingTreeSnapshot(worktree: root)
                ?? LatticeGitWorkspaceCheckpoint.captureHead(worktree: root)
        } else {
            burstGitStartOID = nil
        }
        persistSession()
        isRunning = true
        livePhase = .idea
        lastTurnUsage = nil
        requestTranscriptScrollToBottom(immediate: true)
        compactionRunForThisAgentBurst = false
        agentTask = Task {
            defer {
                isRunning = false
                livePhase = nil
            }
            await agenticLoop(apiKey: apiKey, context: context)
        }
    }

    private func ingestAssistantHintsFromLastAssistantText() {
        for item in items.reversed() {
            if case .assistant(let text, let streaming) = item.kind, !streaming {
                if let hints = AssistantProjectFooterParser.parse(fromAssistantMarkdown: text) {
                    pendingInspectorHints = hints
                }
                if let metadata = AssistantProjectFooterParser.parseDirectorMetadata(fromAssistantText: text),
                   let summary = metadata.projectSummary {
                    projectSummary = projectSummary?.merged(with: summary) ?? summary
                }
                return
            }
        }
    }

    private func maybeAutoCompactHistory(apiKey _: String, context: ChatContext) async {
        guard !compactionRunForThisAgentBurst else { return }
        let budget = LatticeContextLimits.inputTokenBudget(modelId: context.model, providerRaw: context.provider)
        let hist = LatticeContextEstimator.approximateChatHistoryTokens(for: conversationHistory)
        let inst = LLMService.approximateLatticeInstructionPayloadTokens(context: context)
        let billed = hist + inst.system + inst.tools
        let fill = Double(billed) / Double(max(1, budget))
        guard fill >= compactionFillThreshold else { return }
        guard conversationHistory.count > compactionMinHistoryMessages else { return }
        guard conversationHistory.count > compactionVerbatimTailMessages + 4 else { return }
        compactionRunForThisAgentBurst = true

        var trimmed = conversationHistory
        let targetBudget = Int(Double(budget) * 0.90)
        while trimmed.count > compactionVerbatimTailMessages + 2 {
            let current = LatticeContextEstimator.approximateChatHistoryTokens(for: trimmed) + inst.system + inst.tools
            if current <= targetBudget { break }
            trimmed.removeFirst()
        }

        if trimmed.count < conversationHistory.count {
            conversationHistory = trimmed
            pendingRetry = nil
            persistSession()
        }
    }

    private static func removeOldestHistoryMessages(_ history: inout [[String: Any]], keepLast: Int) {
        let k = max(2, keepLast)
        while history.count > k {
            history.removeFirst()
        }
    }

    func send(
        _ text: String,
        attachments: [LatticeImageAttachment] = [],
        apiKey: String,
        context: ChatContext,
        showUserBubble: Bool = true
    ) {
        guard !text.isEmpty || !attachments.isEmpty, !apiKey.isEmpty else { return }
        if isRunning, showUserBubble { return }

        if showUserBubble {
            pendingRetry = nil
            items.append(ChatItem(kind: .user(text, attachments: attachments)))
            if !scopedProjectPath.isEmpty {
                consoleStore?.beginSession(
                    title: "Agent pass",
                    category: "agent",
                    projectPath: scopedProjectPath
                )
            }
        }

        let outbound = outboundUserContent(forAPI: text, attachments: attachments, context: context)

        guard !isRunning else { return }

        isRunning = true
        livePhase = .idea
        lastTurnUsage = nil
        compactionRunForThisAgentBurst = false
        conversationHistory.append(["role": "user", "content": outbound])
        if showUserBubble {
            burstKeepItemsPrefixCount = items.count
            burstKeepHistoryPrefixCount = conversationHistory.count
            burstFileUndos.removeAll()
            refreshBurstGitStartFromBaseline()
            requestTranscriptScrollToBottom(immediate: true)
        }

        agentTask = Task {
            defer {
                isRunning = false
                livePhase = nil
            }
            await agenticLoop(apiKey: apiKey, context: context)
        }
    }

    /// First user message for this project (once per folder): ask the model to verify the local dev environment via bash.
    private func outboundUserContent(
        forAPI text: String,
        attachments: [LatticeImageAttachment],
        context: ChatContext
    ) -> Any {
        let baseText = outboundUserTextForAPI(text)
        let effectiveText: String
        if !baseText.isEmpty {
            effectiveText = baseText
        } else if !attachments.isEmpty {
            let noun = attachments.count == 1 ? "image" : "images"
            effectiveText = "The user attached \(attachments.count) \(noun) without any additional text. Inspect the attached \(noun) and help based on them."
        } else {
            effectiveText = ""
        }

        let contextualized = contextualizedMessage(effectiveText, context: context)
        guard !attachments.isEmpty else { return contextualized }

        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": contextualized
        ]]
        for attachment in attachments {
            blocks.append([
                "type": "local_image",
                "path": attachment.path,
                "mime_type": attachment.mimeType,
                "file_name": attachment.fileName
            ])
        }
        return blocks
    }

    private func outboundUserTextForAPI(_ text: String) -> String {
        guard !scopedProjectPath.isEmpty else { return text }
        guard !ChatSessionPersistence.didCompleteEnvironmentIntro(projectPath: scopedProjectPath) else { return text }
        ChatSessionPersistence.markEnvironmentIntroCompleted(projectPath: scopedProjectPath)
        return Self.firstProjectMessageEnvironmentPreamble + "\n\n" + text
    }

    private static let firstProjectMessageEnvironmentPreamble = """
[Lattice — one-time environment check for this project]
Run only a very short local sanity check first, using a couple of non-interactive commands such as `xcodebuild -version`, `xcode-select -p`, and when relevant `xcrun simctl list runtimes 2>&1 | head -35`.
If the environment looks usable, continue straight into the user’s actual request in the same turn. Do not spend the whole reply on setup commentary, file plans, or broad requirement restatement.
Only stop and ask the user to fix something if the environment is genuinely blocked.
---
"""

    func stop() {
        agentTask?.cancel()
        agentTask = nil
        isRunning = false
        livePhase = nil
        pendingRetry = nil
        persistSession()
    }

    /// Keeps `simulator_use` pointed at the current run target and app identity.
    func updateToolRunContext(simulatorUDID: String?, appBundleID: String?) {
        toolSimulatorUDID = simulatorUDID
        toolAppBundleID = appBundleID
    }

    func clear() {
        items.removeAll()
        conversationHistory.removeAll()
        pendingRetry = nil
        livePhase = nil
        burstFileUndos.removeAll()
        burstGitStartOID = nil
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            let fp = ChatSessionPersistence.projectStorageFingerprint(path: root)
            LatticeGitWorkspaceCheckpoint.clearRetryBaseline(projectFingerprint: fp)
        }
        ChatSessionPersistence.clear(projectPath: scopedProjectPath)
        LatticeChatRestoreHistory.clear(projectPath: scopedProjectPath)
        chatRestorePointHeaders = []
        projectSummary = nil
    }

    private static func lastUserTextForHistoryRestore(from items: [ChatItem]) -> String {
        for item in items.reversed() {
            if case .user(let text, _) = item.kind {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func assistantTurnAnchorIdForLatestCompletedBurst(from items: [ChatItem], startingAt startIndex: Int) -> UUID? {
        guard startIndex >= 0, startIndex < items.count else { return nil }
        for item in items[startIndex...] {
            switch item.kind {
            case .assistant, .tool, .reasoning:
                return item.id
            case .user, .working:
                continue
            }
        }
        return nil
    }

    // MARK: - Agentic loop

    private func agenticLoop(apiKey: String, context: ChatContext) async {
        while true {
            await maybeAutoCompactHistory(apiKey: apiKey, context: context)

            var streamingTextIdx: Int?    // index into items[] of the current assistant text bubble
            var streamingReasoningIdx: Int?
            var toolItemIdxBySSE: [Int: Int] = [:]   // SSE block index → items[] index

            var finishedBlocks: [Int: ContentBlock] = [:]
            var stopReason = "end_turn"

            let itemsCountBeforeStream = items.count
            var retryDelay: UInt64 = 1_000_000_000
            var networkAttempt = 0

            var streamedAnyChunks = false
            networkRetry: while true {
                if networkAttempt > 0 {
                    if !streamedAnyChunks {
                        items.removeSubrange(itemsCountBeforeStream...)
                    }
                    streamingTextIdx = nil
                    streamingReasoningIdx = nil
                    toolItemIdxBySSE = [:]
                    finishedBlocks = [:]
                    stopReason = "end_turn"
                    requestTranscriptScrollToBottom(immediate: true)
                    try? await Task.sleep(nanoseconds: retryDelay)
                    retryDelay = min(retryDelay * 2, 8_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                let workingItem = ChatItem(kind: .working)
                items.append(workingItem)
                let workingId = workingItem.id
                var didRemoveWorking = false
                func removeWorkingPlaceholder() {
                    guard !didRemoveWorking else { return }
                    if let idx = items.firstIndex(where: { $0.id == workingId }) {
                        items.remove(at: idx)
                        didRemoveWorking = true
                        requestTranscriptScrollToBottom(immediate: true)
                    }
                }
                func pruneEmptyReasoning(at index: Int?) {
                    guard let index else { return }
                    guard items.indices.contains(index) else { return }
                    if case .reasoning(let text, _) = items[index].kind,
                       text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.remove(at: index)
                    }
                }

                do {
                    for try await chunk in service.stream(
                        messages: conversationHistory,
                        apiKey: apiKey,
                        context: context
                    ) {
                        streamedAnyChunks = true
                        switch chunk {

                        case .reasoningDelta(let delta):
                            let cleaned = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty else { continue }
                            livePhase = .plan
                            removeWorkingPlaceholder()
                            if let i = streamingReasoningIdx {
                                items[i].appendReasoning(delta)
                            } else {
                                if let ti = streamingTextIdx {
                                    items[ti].finalizeText()
                                    streamingTextIdx = nil
                                }
                                items.append(ChatItem(kind: .reasoning(delta, isStreaming: true)))
                                streamingReasoningIdx = items.count - 1
                            }
                            noteTranscriptScrollIntent()

                        case .textDelta(let delta):
                            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                livePhase = .polish
                            }
                            removeWorkingPlaceholder()
                            if let i = streamingReasoningIdx {
                                items[i].finalizeReasoning()
                                streamingReasoningIdx = nil
                            }
                            if let i = streamingTextIdx {
                                items[i].appendText(delta)
                            } else {
                                let item = ChatItem(kind: .assistant(delta, isStreaming: true))
                                streamingTextIdx = items.count
                                items.append(item)
                            }
                            noteTranscriptScrollIntent()

                        case .toolCallAnnounced(let sseIdx, _, let name):
                            livePhase = .build
                            removeWorkingPlaceholder()
                            if let i = streamingReasoningIdx {
                                items[i].finalizeReasoning()
                                pruneEmptyReasoning(at: i)
                                streamingReasoningIdx = nil
                            }
                            if let i = streamingTextIdx {
                                items[i].finalizeText()
                                streamingTextIdx = nil
                            }
                            let item = ChatItem(kind: .tool(
                                name: name, input: "", output: nil, isError: false, isRunning: true
                            ))
                            toolItemIdxBySSE[sseIdx] = items.count
                            items.append(item)
                            requestTranscriptScrollToBottom(immediate: true)

                        case .done(let reason, let blocks, let usage):
                            stopReason = reason
                            finishedBlocks = blocks
                            lastTurnUsage = usage

                            if let i = streamingReasoningIdx {
                                items[i].finalizeReasoning()
                                pruneEmptyReasoning(at: i)
                                streamingReasoningIdx = nil
                            }
                            if let i = streamingTextIdx {
                                items[i].finalizeText()
                            }

                            // Fill in tool inputs now that they're fully streamed
                            for (sseIdx, itemsIdx) in toolItemIdxBySSE {
                                if let block = blocks[sseIdx] {
                                    items[itemsIdx].setToolInput(
                                        displayInput(name: block.toolName ?? "", json: block.toolInputJSON ?? "")
                                    )
                                }
                            }
                            requestTranscriptScrollToBottom(immediate: true)
                        }
                    }
                    removeWorkingPlaceholder()
                    break networkRetry
                } catch is CancellationError {
                    removeWorkingPlaceholder()
                    return
                } catch let err as URLError {
                    removeWorkingPlaceholder()
                    if err.code == .timedOut {
                        if streamedAnyChunks {
                            // Keep the partial response visible without appending a noisy error card.
                            return
                        }
                        networkAttempt += 1
                        if networkAttempt > 5 {
                            appendAssistantFailure("Error: Request timed out. Please try again.")
                            return
                        }
                        continue
                    }
                    if streamedAnyChunks {
                        appendAssistantFailure(
                            "Error: Connection interrupted while streaming. Please retry.\n\n\(APIErrorFormatting.userFacingMessage(from: err))"
                        )
                        return
                    }
                    networkAttempt += 1
                    if networkAttempt > 3 {
                        appendAssistantFailure("Error: \(APIErrorFormatting.userFacingMessage(from: err))")
                        return
                    }
                } catch {
                    removeWorkingPlaceholder()
                    appendAssistantFailure("Error: \(APIErrorFormatting.userFacingMessage(from: error))")
                    return
                }
            }

            guard !Task.isCancelled else { return }

            // Append assistant turn to history (text + tool_use blocks, in SSE order)
            let assistantContent = finishedBlocks
                .sorted { $0.key < $1.key }
                .map { $0.value.toAPIDict() }
                .filter { !$0.isEmpty }

            if !assistantContent.isEmpty {
                conversationHistory.append(["role": "assistant", "content": assistantContent])
                ingestAssistantHintsFromLastAssistantText()
                pendingRetry = nil
            }

            if stopReason != "tool_use" {
                break
            }

            // Execute each tool call and collect results
            var toolResults: [[String: Any]] = []

            for (sseIdx, block) in finishedBlocks.sorted(by: { $0.key < $1.key }) {
                guard block.type == "tool_use",
                      let toolId = block.toolId,
                      let toolName = block.toolName,
                      let input = block.parsedInput
                else { continue }

                livePhase = .build

                let writeUndo: LatticeWriteFileUndo?
                if toolName == "write_file", let path = input["path"] as? String {
                    writeUndo = LatticeWriteFileUndo.capture(path: path)
                } else {
                    writeUndo = nil
                }

                let (output, isError): (String, Bool)
                if toolName == "write_file",
                   Self.writeApprovalRequired,
                   let path = input["path"] as? String,
                   let newContent = input["content"] as? String {
                    // Pause the loop and let the user review the diff before anything lands.
                    let oldContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    let approved = await requestWriteApproval(
                        PendingFileApproval(path: path, oldContent: oldContent, newContent: newContent)
                    )
                    guard !Task.isCancelled else {
                        conversationHistory.removeLast()
                        return
                    }
                    if approved {
                        (output, isError) = await executor.execute(name: toolName, input: input)
                    } else {
                        (output, isError) = (
                            "The user reviewed the diff and declined this change. Ask what they'd like adjusted, or propose a different approach.",
                            true
                        )
                    }
                } else {
                    (output, isError) = await executor.execute(name: toolName, input: input)
                }

                if toolName == "write_file", let u = writeUndo, !isError {
                    burstFileUndos.append(u)
                }
                if toolName == "add_capability" || toolName == "remove_capability" {
                    capabilityRefreshToken += 1
                }
                consoleStore?.append(
                    output,
                    category: "\(toolName)\(isError ? " (error)" : "")",
                    projectPath: scopedProjectPath
                )

                guard !Task.isCancelled else {
                    // Roll back the assistant turn so the next send() starts from a clean history.
                    conversationHistory.removeLast()
                    return
                }

                if let itemsIdx = toolItemIdxBySSE[sseIdx] {
                    items[itemsIdx].setToolResult(output, isError: isError)
                    requestTranscriptScrollToBottom(immediate: true)
                }

                // Show the model the outcome of a UI-changing simulator action.
                var screenshotPath: String?
                if toolName == "simulator_use", !isError,
                   let action = input["action"] as? String,
                   ["screenshot", "end_session", "home"].contains(action) == false,
                   let udid = executor.simulatorUDID {
                    screenshotPath = try? await SimulatorScreenshot.capture(deviceUDID: udid).path
                }

                toolResults.append(toolResultMessage(
                    toolUseId: toolId, content: output, isError: isError, screenshotPath: screenshotPath
                ))
                livePhase = .verify
            }

            if !toolResults.isEmpty {
                conversationHistory.append(["role": "user", "content": toolResults])
            }
        }
        let snap = persistGitBaselineAfterQuietTurnCompletion()
        let root = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            LatticeChatRestoreHistory.appendCompletedTurn(
                projectPath: root,
                userLine: Self.lastUserTextForHistoryRestore(from: items),
                userText: Self.lastUserTextForHistoryRestore(from: items),
                preTurnGitOID: burstGitStartOID,
                assistantTurnAnchorId: Self.assistantTurnAnchorIdForLatestCompletedBurst(
                    from: items,
                    startingAt: burstKeepItemsPrefixCount
                ),
                gitTreeOID: snap,
                projectSummary: projectSummary,
                items: items,
                conversationHistory: conversationHistory
            )
            reloadChatRestorePointHeaders()
        }
        persistSession()
    }

    private func contextualizedMessage(_ text: String, context: ChatContext) -> String {
        guard let prefix = context.messagePrefix else { return text }
        return """
        \(prefix)

        [User Message]
        \(text)
        """
    }

    // Pretty-print tool input for display
    private func displayInput(name: String, json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        switch name {
        case "bash":           return "$ \(obj["command"] as? String ?? "")"
        case "read_file":      return "cat \(obj["path"] as? String ?? "")"
        case "write_file":     return "→ \(obj["path"] as? String ?? "")"
        default:               return json
        }
    }
}

func nonEmptyTrimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

import AppKit
import Combine
import SwiftUI

// MARK: - Transcript layout (reading column: assistant leading, user trailing)

/// Column width for transcript; centered in the window; rows align content inside it.
private let latticeTranscriptColumnMaxWidth: CGFloat = 720
private let latticeUserBubbleMaxWidth: CGFloat = 380
/// Assistant markdown reads best a bit narrower than the full column.
private let latticeAssistantProseMaxWidth: CGFloat = 560
/// Consecutive tool runs this long collapse into one disclosure by default.
private let latticeToolRunBatchThreshold: Int = 3

extension Notification.Name {
    static let latticeOpenWelcomeHub = Notification.Name("latticeOpenWelcomeHub")
    static let latticeRunOnSimulator = Notification.Name("latticeRunOnSimulator")
    static let latticeOpenSettingsWindow = Notification.Name("latticeOpenSettingsWindow")
}

// MARK: - View Model (agentic loop)

struct BuildInfo: Sendable {
    var schemeName: String
    var projectPath: String
    var simulatorID: String?
}

struct ChatContext: Equatable {
    let runTarget: String?
    let projectPath: String?
    let model: String
    let provider: String
    /// When provider is z.ai: `true` uses the GLM Coding Plan API base URL; `false` uses pay-as-you-go credits API.
    let zaiUseCodingEndpoint: Bool
    let buildInfo: BuildInfo?
    let bundleIdentifierOverride: String?
    let developmentTeam: String?

    static func == (lhs: ChatContext, rhs: ChatContext) -> Bool {
        lhs.runTarget == rhs.runTarget &&
        lhs.projectPath == rhs.projectPath &&
        lhs.model == rhs.model &&
        lhs.provider == rhs.provider &&
        lhs.zaiUseCodingEndpoint == rhs.zaiUseCodingEndpoint &&
        lhs.buildInfo?.schemeName == rhs.buildInfo?.schemeName &&
        lhs.buildInfo?.projectPath == rhs.buildInfo?.projectPath &&
        lhs.buildInfo?.simulatorID == rhs.buildInfo?.simulatorID &&
        lhs.bundleIdentifierOverride == rhs.bundleIdentifierOverride &&
        lhs.developmentTeam == rhs.developmentTeam
    }

    var messagePrefix: String? {
        var sections: [String] = []

        if let runTarget, !runTarget.isEmpty {
            sections.append("""
            [Selected Run Target]
            \(runTarget)
            """)
        }

        if let projectPath, !projectPath.isEmpty {
            sections.append("""
            [Selected Project Path]
            \(projectPath)
            """)
        }

        if let info = buildInfo {
            var buildSection = """
            [Known Build Configuration — SKIP PHASE 0 AND PHASE 1]
            The project has already been discovered. Use these exact values and go directly to PHASE 4:
            - Project path: \(info.projectPath)
            - Scheme: \(info.schemeName)
            """
            if let simID = info.simulatorID {
                buildSection += "\n- Simulator ID: \(simID)"
            }
            sections.append(buildSection)
        }

        if let bid = bundleIdentifierOverride, !bid.isEmpty {
            sections.append("""
            [Bundle Identifier Override]
            \(bid)
            """)
        }
        if let team = developmentTeam, !team.isEmpty {
            sections.append("""
            [Development Team]
            \(team)
            """)
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}

@MainActor
final class SimulatorStore: ObservableObject {
    @Published private(set) var simulators: [SimulatorOption] = []
    @Published private(set) var connectedDevices: [ConnectedDeviceOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil

        Task {
            do {
                let simulators = try await fetchSimulators()
                let devices = try await fetchConnectedDevices()
                isLoading = false
                self.simulators = simulators
                self.connectedDevices = devices
            } catch {
                isLoading = false
                self.simulators = []
                self.connectedDevices = []
                self.loadError = error.localizedDescription
            }
        }
    }

    private func fetchSimulators() async throws -> [SimulatorOption] {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "available", "-j"]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let errorOutput = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                guard process.terminationStatus == 0 else {
                    let message = errorOutput.isEmpty ? "Unable to load simulators." : errorOutput
                    continuation.resume(throwing: SimulatorLoadError.message(
                        message.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }

                do {
                    let devices = try Self.parseSimulators(from: output)
                    continuation.resume(returning: devices)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func parseSimulators(from json: String) throws -> [SimulatorOption] {
        struct SimctlResponse: Decodable {
            let devices: [String: [SimDevice]]
        }

        struct SimDevice: Decodable {
            let name: String
            let udid: String
            let isAvailable: Bool?
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(SimctlResponse.self, from: Data(json.utf8))

        return response.devices
            .flatMap { runtimeKey, devices -> [SimulatorOption] in
                let runtime = runtimeName(from: runtimeKey)
                return devices.compactMap { device -> SimulatorOption? in
                    guard device.isAvailable != false else { return nil }
                    return SimulatorOption(id: device.udid, name: device.name, runtime: runtime)
                }
            }
            .sorted {
                if $0.runtime == $1.runtime {
                    return $0.name < $1.name
                }
                return $0.runtime > $1.runtime
            }
    }

    nonisolated private static func runtimeName(from runtimeKey: String) -> String {
        let rawName = runtimeKey.split(separator: ".").last.map(String.init) ?? runtimeKey
        return rawName
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "iOS ", with: "iOS ")
    }

    private func fetchConnectedDevices() async throws -> [ConnectedDeviceOption] {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctrace", "list", "devices"]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let errorOutput = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                guard process.terminationStatus == 0 else {
                    let message = errorOutput.isEmpty ? "Unable to load connected devices." : errorOutput
                    continuation.resume(throwing: SimulatorLoadError.message(
                        message.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }
                continuation.resume(returning: Self.parseConnectedDevices(from: output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func parseConnectedDevices(from text: String) -> [ConnectedDeviceOption] {
        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        var inDevicesSection = false
        var result: [ConnectedDeviceOption] = []

        for line in lines {
            if line == "== Devices ==" {
                inDevicesSection = true
                continue
            }
            if line.hasPrefix("== "), inDevicesSection {
                break
            }
            guard inDevicesSection, !line.isEmpty else { continue }
            // Example: "Olivers iPhone (18.5) (00008110-...)"
            guard let idStart = line.lastIndex(of: "("),
                  line.hasSuffix(")"),
                  idStart < line.index(before: line.endIndex)
            else { continue }
            let id = String(line[line.index(after: idStart)..<line.index(before: line.endIndex)])
            if id.count < 8 { continue }
            let prefix = String(line[..<idStart]).trimmingCharacters(in: .whitespaces)
            guard let runtimeStart = prefix.lastIndex(of: "("),
                  prefix.hasSuffix(")") else { continue }
            let platform = String(prefix[prefix.index(after: runtimeStart)..<prefix.index(before: prefix.endIndex)])
            let name = String(prefix[..<runtimeStart]).trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            if lower.contains("simulator") || lower == "mac" || lower.contains("placeholder") { continue }
            result.append(ConnectedDeviceOption(id: id, name: name, platform: platform))
        }
        return result
    }

    private enum SimulatorLoadError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    @Published var changeCount = 0  // incremented on every streaming update → scroll trigger

    private let service = LLMService()
    private let executor = ToolExecutor()
    private weak var consoleStore: LatticeConsoleStore?
    private var conversationHistory: [[String: Any]] = []
    private var agentTask: Task<Void, Never>?
    private var messageQueue: [QueuedMessage] = []
    /// Matches `selectedProjectPath` from the main window (trimmed); drives per-project persistence.
    private var scopedProjectPath: String = ""

    init(consoleStore: LatticeConsoleStore? = nil) {
        self.consoleStore = consoleStore
    }

    /// Call when the selected project folder changes so each project keeps its own transcript + agent history.
    func syncProjectPath(_ rawPath: String) {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != scopedProjectPath else { return }

        if isRunning {
            agentTask?.cancel()
            agentTask = nil
            messageQueue.removeAll()
            isRunning = false
        }

        if !items.isEmpty || !conversationHistory.isEmpty {
            persistSession()
        }

        scopedProjectPath = path
        items = ChatSessionPersistence.loadItems(projectPath: path)
        conversationHistory = ChatSessionPersistence.loadHistory(projectPath: path)
        changeCount += 1
    }

    func persistSession() {
        ChatSessionPersistence.saveItems(items, projectPath: scopedProjectPath)
        ChatSessionPersistence.saveHistory(conversationHistory, projectPath: scopedProjectPath)
    }

    func send(_ text: String, apiKey: String, context: ChatContext, showUserBubble: Bool = true) {
        guard !text.isEmpty, !apiKey.isEmpty else { return }

        if showUserBubble {
            items.append(ChatItem(kind: .user(text)))
        }

        let outbound = outboundUserContent(forAPI: text)

        if isRunning {
            messageQueue.append(QueuedMessage(text: outbound, context: context))
            return
        }

        isRunning = true
        conversationHistory.append(["role": "user", "content": contextualizedMessage(outbound, context: context)])

        agentTask = Task {
            defer { isRunning = false }
            await agenticLoop(apiKey: apiKey, context: context)
        }
    }

    /// First user message for this project (once per folder): ask the model to verify the local dev environment via bash.
    private func outboundUserContent(forAPI text: String) -> String {
        guard !scopedProjectPath.isEmpty else { return text }
        guard !ChatSessionPersistence.didCompleteEnvironmentIntro(projectPath: scopedProjectPath) else { return text }
        ChatSessionPersistence.markEnvironmentIntroCompleted(projectPath: scopedProjectPath)
        return Self.firstProjectMessageEnvironmentPreamble + "\n\n" + text
    }

    private static let firstProjectMessageEnvironmentPreamble = """
[Lattice — one-time environment check for this project]
Before anything else, run quick non-interactive shell checks such as:
`xcodebuild -version`, `xcode-select -p`, and `xcrun simctl list runtimes 2>&1 | head -35`.
Summarize what works on this Mac and list clearly what the user must fix manually (install or update Xcode, open Xcode once to finish installing components, accept the license with `sudo xcodebuild -license accept`, install simulator runtimes in Xcode Settings, etc.). Keep this short, then answer the user’s actual request below.
---
"""

    func stop() {
        agentTask?.cancel()
        agentTask = nil
        messageQueue.removeAll()
        isRunning = false
        persistSession()
    }

    func clear() {
        items.removeAll()
        conversationHistory.removeAll()
        ChatSessionPersistence.clear(projectPath: scopedProjectPath)
    }

    // MARK: - Agentic loop

    private func agenticLoop(apiKey: String, context: ChatContext) async {
        while true {
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
                    changeCount += 1
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
                        changeCount += 1
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
                            changeCount += 1

                        case .textDelta(let delta):
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
                            changeCount += 1

                        case .toolCallAnnounced(let sseIdx, _, let name):
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
                            changeCount += 1

                        case .done(let reason, let blocks):
                            stopReason = reason
                            finishedBlocks = blocks

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
                            changeCount += 1
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
                            items.append(ChatItem(kind: .assistant(
                                "Error: Request timed out. Please try again.",
                                isStreaming: false
                            )))
                            changeCount += 1
                            return
                        }
                        continue
                    }
                    if streamedAnyChunks {
                        items.append(ChatItem(kind: .assistant(
                            "Error: Connection interrupted while streaming. Please retry.\n\n\(APIErrorFormatting.userFacingMessage(from: err))",
                            isStreaming: false
                        )))
                        changeCount += 1
                        return
                    }
                    networkAttempt += 1
                    if networkAttempt > 3 {
                        items.append(ChatItem(kind: .assistant(
                            "Error: \(APIErrorFormatting.userFacingMessage(from: err))", isStreaming: false
                        )))
                        changeCount += 1
                        return
                    }
                } catch {
                    removeWorkingPlaceholder()
                    items.append(ChatItem(kind: .assistant(
                        "Error: \(APIErrorFormatting.userFacingMessage(from: error))", isStreaming: false
                    )))
                    changeCount += 1
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
            }

            if stopReason != "tool_use" {
                guard !messageQueue.isEmpty, !Task.isCancelled else { break }
                let next = messageQueue.removeFirst()
                conversationHistory.append([
                    "role": "user",
                    "content": contextualizedMessage(next.text, context: next.context)
                ])
                continue
            }

            if let next = takeLatestQueuedMessage() {
                let supersededMessage = "Skipped because a newer queued message superseded this tool call."
                var skippedToolResults: [[String: Any]] = []

                for (_, block) in finishedBlocks.sorted(by: { $0.key < $1.key }) {
                    guard block.type == "tool_use", let toolId = block.toolId else { continue }
                    skippedToolResults.append(toolResultMessage(
                        toolUseId: toolId,
                        content: supersededMessage,
                        isError: false
                    ))
                }

                for itemsIdx in toolItemIdxBySSE.values {
                    items[itemsIdx].setToolResult(supersededMessage, isError: false)
                }
                changeCount += 1

                var userContent = skippedToolResults
                userContent.append([
                    "type": "text",
                    "text": contextualizedMessage(next.text, context: next.context)
                ])
                conversationHistory.append(["role": "user", "content": userContent])
                continue
            }

            // Execute each tool call and collect results
            var toolResults: [[String: Any]] = []

            for (sseIdx, block) in finishedBlocks.sorted(by: { $0.key < $1.key }) {
                guard block.type == "tool_use",
                      let toolId = block.toolId,
                      let toolName = block.toolName,
                      let input = block.parsedInput
                else { continue }

                let (output, isError) = await executor.execute(name: toolName, input: input)
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
                    changeCount += 1
                }

                toolResults.append(toolResultMessage(
                    toolUseId: toolId, content: output, isError: isError
                ))
            }

            if !toolResults.isEmpty {
                conversationHistory.append(["role": "user", "content": toolResults])
            }
        }
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
        case "open_spec_docs": return obj["change_name"] as? String ?? ""
        default:               return json
        }
    }

    private func takeLatestQueuedMessage() -> QueuedMessage? {
        guard let latest = messageQueue.last else { return nil }
        messageQueue.removeAll()
        return latest
    }

    private struct QueuedMessage {
        let text: String
        let context: ChatContext
    }
}

// MARK: - Chat transcript rows (grouped)

private enum ChatDisplayRow: Identifiable {
    case user(ChatItem)
    case working(ChatItem)
    case assistantTurn(anchorId: UUID, items: [ChatItem])

    var id: UUID {
        switch self {
        case .user(let item): return item.id
        case .working(let item): return item.id
        case .assistantTurn(let anchorId, _): return anchorId
        }
    }
}

// MARK: - Root View

struct ContentView: View {
    @ObservedObject var simulatorStore: SimulatorStore
    @ObservedObject var generationState: LatticeGenerationState
    @ObservedObject var consoleStore: LatticeConsoleStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var viewModel: ChatViewModel
    @StateObject private var recentStore = RecentProjectsStore()
    @AppStorage("anthropicAPIKey") private var anthropicKey = ""
    @AppStorage("openAIAPIKey") private var openAIKey = ""
    @AppStorage("zaiAPIKey") private var zaiKey = ""
    @AppStorage("zaiUseCodingEndpoint") private var zaiUseCodingEndpoint = true
    @AppStorage("selectedProvider") private var selectedProvider = "anthropic"
    @AppStorage("selectedSimulatorID") private var selectedSimulatorID = ""
    @AppStorage("selectedProjectPath") private var selectedProjectPath = ""
    @AppStorage("selectedModel") private var selectedModel = "claude-sonnet-4-6"
    @AppStorage("latticeLocalRunDestination") private var latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSSimulator.rawValue
    @AppStorage("latticeAppearancePreference") private var latticeAppearancePreference = "system"
    @AppStorage("latticeShowComposerTips") private var latticeShowComposerTips = true
    @AppStorage("latticeAccentTag") private var latticeAccentTag = "system"
    @AppStorage("latticeDevelopmentTeam") private var latticeDevelopmentTeam = ""
    @AppStorage("latticeGlobalDevelopmentTeam") private var latticeGlobalDevelopmentTeam = ""
    @AppStorage("latticeBundleIdentifierOverride") private var latticeBundleIdentifierOverride = ""
    @State private var input = ""
    @State private var showProjectPanel = false
    @State private var showProjectHub = false
    @State private var isDirectRunInProgress = false
    @State private var composerTipIndex = 0
    @State private var directRunBanner: String?
    @State private var directRunBannerIsError = false
    @State private var launchHubApplied = false
    @State private var showCopyToast = false
    @State private var copyToastText = "Copied"
    @State private var supportedRunDestinations: Set<LatticeLocalRunDestination> = .allRunDestinations
    @State private var discoveredDevelopmentTeams: [String] = []
    @State private var showSigningHelpPopover = false

    private let composerTips = [
        "Shift+Return for newline",
        "Return sends the message",
        "Build & Run uses local xcodebuild (no chat)",
    ]

    @State private var showConsoleSheet = false
    @State private var consoleSearch = ""

    init(simulatorStore: SimulatorStore, generationState: LatticeGenerationState, consoleStore: LatticeConsoleStore) {
        self.simulatorStore = simulatorStore
        self.generationState = generationState
        self.consoleStore = consoleStore
        _viewModel = StateObject(wrappedValue: ChatViewModel(consoleStore: consoleStore))
    }

    private var activeAPIKey: String {
        switch LLMProvider(rawValue: selectedProvider) ?? .anthropic {
        case .anthropic: return anthropicKey
        case .openAI: return openAIKey
        case .zai: return zaiKey
        }
    }

    private var localRunDestination: LatticeLocalRunDestination {
        LatticeLocalRunDestination(rawValue: latticeLocalRunDestinationRaw) ?? .iOSSimulator
    }

    private var simulatorsForToolbar: [SimulatorOption] {
        guard supportedRunDestinations.contains(localRunDestination) else { return [] }
        switch localRunDestination {
        case .iOSSimulator:
            return simulatorStore.simulators.filter { $0.matches(filter: .iOS) }
        case .iOSDevice:
            return []
        case .watchOSSimulator:
            return simulatorStore.simulators.filter { $0.matches(filter: .watchOS) }
        case .macOS:
            return []
        }
    }

    private var devicesForToolbar: [ConnectedDeviceOption] {
        guard supportedRunDestinations.contains(.iOSDevice) else { return [] }
        let all = simulatorStore.connectedDevices
        if supportedRunDestinations.contains(.watchOSSimulator) {
            return all
        }
        return all.filter { !$0.isAppleWatch }
    }

    /// Inspector Team ID wins; otherwise Settings default Team ID.
    private var resolvedDevelopmentTeam: String? {
        let project = latticeDevelopmentTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { return project }
        let global = latticeGlobalDevelopmentTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? nil : global
    }

    private var runTargetLabel: String {
        switch localRunDestination {
        case .macOS:
            return "My Mac"
        case .iOSDevice:
            if let label = devicesForToolbar.first(where: { $0.id == selectedSimulatorID })?.label {
                return label
            }
            return selectedSimulatorID.isEmpty ? "Connected device" : "Device (\(selectedSimulatorID.prefix(6)))"
        case .iOSSimulator, .watchOSSimulator:
            if let label = simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID })?.label {
                return label
            }
            return selectedSimulatorID.isEmpty ? "Simulator" : "Simulator (\(selectedSimulatorID.prefix(6)))"
        }
    }

    private var preferredAppearance: ColorScheme? {
        switch latticeAppearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var accentTint: Color? {
        switch latticeAccentTag {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        default: return nil
        }
    }

    private var hasSelectedProject: Bool {
        !selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredConsoleText: String {
        let query = consoleSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = consoleStore.lines
        if query.isEmpty {
            return lines.joined(separator: "\n")
        }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }

    var body: some View {
        ZStack {
            buildRunBackdrop
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                contextBar
                Divider()
                if let banner = directRunBanner {
                    directRunBannerView(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                messageList
                Divider()
                inputBar
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: directRunBanner != nil)
        .preferredColorScheme(preferredAppearance)
        .tint(accentTint)
        .sheet(isPresented: $showConsoleSheet) {
            NavigationStack {
                VStack(spacing: 0) {
                    TextField("Search log", text: $consoleSearch)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        .padding(.top, 12)
                    ScrollView {
                        Text(filteredConsoleText)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .navigationTitle("Console")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showConsoleSheet = false }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy") {
                            copyTextAndToast(filteredConsoleText, toast: "Log copied")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) {
                            consoleStore.clear(projectPath: selectedProjectPath)
                        }
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 440)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                if !selectedProjectPath.isEmpty, !showProjectHub {
                    Button(action: runOnSimulatorDirect) {
                        if isDirectRunInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            Label("Build & Run", systemImage: "play.fill")
                        }
                    }
                    .help(buildRunHelp)
                    .disabled(!canLocalBuildAndRun)

                    Menu {
                        if supportedRunDestinations.contains(.macOS) {
                            Section("My Mac") {
                                Button {
                                    latticeLocalRunDestinationRaw = LatticeLocalRunDestination.macOS.rawValue
                                    selectedSimulatorID = ""
                                } label: {
                                    Label("My Mac", systemImage: localRunDestination == .macOS ? "checkmark" : "laptopcomputer")
                                }
                            }
                        }

                        if supportedRunDestinations.contains(.iOSSimulator) || supportedRunDestinations.contains(.watchOSSimulator) {
                            Section("Simulators") {
                                if supportedRunDestinations.contains(.iOSSimulator) {
                                    ForEach(simulatorStore.simulators.filter { $0.matches(filter: .iOS) }) { sim in
                                        Button {
                                            latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSSimulator.rawValue
                                            selectedSimulatorID = sim.id
                                        } label: {
                                            Label(sim.name, systemImage: (localRunDestination == .iOSSimulator && selectedSimulatorID == sim.id) ? "checkmark" : "iphone")
                                        }
                                    }
                                }
                                if supportedRunDestinations.contains(.watchOSSimulator) {
                                    ForEach(simulatorStore.simulators.filter { $0.matches(filter: .watchOS) }) { sim in
                                        Button {
                                            latticeLocalRunDestinationRaw = LatticeLocalRunDestination.watchOSSimulator.rawValue
                                            selectedSimulatorID = sim.id
                                        } label: {
                                            Label(sim.name, systemImage: (localRunDestination == .watchOSSimulator && selectedSimulatorID == sim.id) ? "checkmark" : "applewatch")
                                        }
                                    }
                                }
                            }
                        }

                        if supportedRunDestinations.contains(.iOSDevice) {
                            Section("Connected devices") {
                                if devicesForToolbar.isEmpty {
                                    Text("No connected devices")
                                } else {
                                    ForEach(devicesForToolbar) { device in
                                        Button {
                                            latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSDevice.rawValue
                                            selectedSimulatorID = device.id
                                        } label: {
                                            Label(device.label, systemImage: (localRunDestination == .iOSDevice && selectedSimulatorID == device.id) ? "checkmark" : device.menuSymbolName)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(runTargetLabel)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            if !showProjectHub {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showProjectHub = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help("Project Hub")
                }
            }
            if hasSelectedProject {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showConsoleSheet = true
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Console for this project")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "lattice-settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            if !showProjectHub {
                ToolbarItem(placement: .automatic) {
                    Button { showProjectPanel.toggle() } label: {
                        Image(systemName: showProjectPanel ? "sidebar.trailing" : "sidebar.right")
                    }
                    .help(showProjectPanel ? "Hide Project" : "Show Project")
                }
            }
        }
        .inspector(isPresented: $showProjectPanel) {
            ProjectInspectorView(
                selectedProjectPath: $selectedProjectPath,
                developmentTeam: $latticeDevelopmentTeam,
                bundleIdentifierOverride: $latticeBundleIdentifierOverride,
                discoveredDevelopmentTeams: discoveredDevelopmentTeams,
                showSigningHelpPopover: $showSigningHelpPopover
            )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if showProjectHub {
                ProjectHubView(
                    recentStore: recentStore,
                    selectedProjectPath: $selectedProjectPath,
                    showProjectHub: $showProjectHub
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity)
                )
            }
        }
        .overlay(alignment: .bottom) {
            if showCopyToast {
                Label(copyToastText, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showProjectHub)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.persistSession()
            }
        }
        .task {
            viewModel.syncProjectPath(selectedProjectPath)
            consoleStore.setVisibleProject(path: selectedProjectPath)
            simulatorStore.refresh()
            refreshProjectDerivedSettings()
        }
        .onAppear {
            generationState.isGenerating = viewModel.isRunning
            if !launchHubApplied {
                launchHubApplied = true
                showProjectHub = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticeOpenWelcomeHub)) { _ in
            showProjectHub = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticeOpenSettingsWindow)) { _ in
            openWindow(id: "lattice-settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticeRunOnSimulator)) { _ in
            runOnSimulatorDirect()
        }
        .onChange(of: viewModel.isRunning) { _, isRunning in
            generationState.isGenerating = isRunning
            if !isRunning {
                viewModel.persistSession()
            }
        }
        .onChange(of: showProjectPanel) { _, isOpen in
            if !isOpen && selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showProjectHub = true
            }
        }
        .onChange(of: selectedProjectPath) { old, new in
            viewModel.syncProjectPath(new)
            consoleStore.setVisibleProject(path: new)
            directRunBanner = nil
            directRunBannerIsError = false
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldTrimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                showProjectHub = true
                supportedRunDestinations = .allRunDestinations
                discoveredDevelopmentTeams = []
            } else if trimmed != oldTrimmed {
                recentStore.add(path: trimmed)
            }
            refreshProjectDerivedSettings()
        }
        .onChange(of: latticeLocalRunDestinationRaw) { _, _ in
            if !supportedRunDestinations.contains(localRunDestination) {
                if let fallback = LatticeLocalRunDestination.allCases.first(where: { supportedRunDestinations.contains($0) }) {
                    latticeLocalRunDestinationRaw = fallback.rawValue
                }
            }
            if !selectedSimulatorID.isEmpty {
                let valid: Bool = {
                    switch localRunDestination {
                    case .iOSDevice:
                        return devicesForToolbar.contains(where: { $0.id == selectedSimulatorID })
                    case .iOSSimulator, .watchOSSimulator:
                        return simulatorsForToolbar.contains(where: { $0.id == selectedSimulatorID })
                    case .macOS:
                        return true
                    }
                }()
                if !valid { selectedSimulatorID = "" }
            }
        }
        .onChange(of: showProjectHub) { _, isHub in
            if isHub {
                directRunBanner = nil
                directRunBannerIsError = false
            }
        }
        .onChange(of: supportedRunDestinations) { _, _ in
            if localRunDestination == .iOSDevice,
               !selectedSimulatorID.isEmpty,
               !devicesForToolbar.contains(where: { $0.id == selectedSimulatorID }) {
                selectedSimulatorID = ""
            }
        }
    }

    private var buildRunBackdrop: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.14),
                            Color.clear,
                            Color.purple.opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [Color.orange.opacity(0.08), Color.clear],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: 420
                    )
                }
            }
        }
    }

    private var buildRunHelp: String {
        switch localRunDestination {
        case .iOSSimulator:
            return "Build with xcodebuild for the selected iOS Simulator (exact UDID), then install and launch with simctl. Does not post to chat."
        case .iOSDevice:
            return "Build for the selected connected iPhone/iPad, install via devicectl, then launch on device. Does not post to chat."
        case .watchOSSimulator:
            return "Build for the selected watchOS Simulator, then install and launch with simctl. Does not post to chat."
        case .macOS:
            return "Build with xcodebuild for My Mac, then open the built .app. Does not post to chat."
        }
    }

    /// Sends build failure output to the agent (or fills the composer if no API key is set).
    private func sendBuildErrorToChat(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            directRunBanner = nil
            directRunBannerIsError = false
            return
        }
        let message = "Fix this error:\n\n\(trimmed)"
        if activeAPIKey.isEmpty {
            input = message
        } else {
            viewModel.send(message, apiKey: activeAPIKey, context: chatContext)
        }
        directRunBanner = nil
        directRunBannerIsError = false
    }

    private func directRunBannerView(_ text: String) -> some View {
        let success = !directRunBannerIsError
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(success ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(success ? "Build succeeded" : "Build failed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(success ? "Local Build & Run completed." : "Review the log or send the error to the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    directRunBanner = nil
                    directRunBannerIsError = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72, maxHeight: 200)

            HStack(spacing: 10) {
                if directRunBannerIsError {
                    Button {
                        sendBuildErrorToChat(text)
                    } label: {
                        Label("Let Lattice fix it", systemImage: "wand.and.stars")
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Let Lattice fix it")
                    .accessibilityHint(activeAPIKey.isEmpty ? "Inserts a fix request into the message field." : "Sends the error to the assistant.")
                    .help(activeAPIKey.isEmpty ? "Fills the message field (add an API key in Settings to send automatically)." : "Send this error to the assistant as a chat message.")
                }

                Button {
                    copyTextAndToast(text, toast: "Copied build output")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .modifier(BuildBannerCopyButtonStyle())

                Button("Full log") {
                    consoleStore.append(text, category: "build", projectPath: selectedProjectPath)
                    consoleSearch = ""
                    showConsoleSheet = true
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    success ? Color.green.opacity(0.35) : Color.orange.opacity(0.45),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Context bar

    private var contextBar: some View {
        let prov = LLMProvider(rawValue: selectedProvider) ?? .anthropic
        let modelLabel = prov.models.first(where: { $0.id == selectedModel })?.label ?? selectedModel
        let folderShort: String = {
            let p = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return "No folder" }
            let name = (p as NSString).lastPathComponent
            return name.count > 28 ? String(name.prefix(25)) + "…" : name
        }()
        let simLabel: String = {
            switch localRunDestination {
            case .macOS:
                return "My Mac"
            case .iOSDevice:
                return devicesForToolbar.first(where: { $0.id == selectedSimulatorID })?.name
                    ?? simulatorStore.connectedDevices.first(where: { $0.id == selectedSimulatorID })?.name
                    ?? "No device"
            case .iOSSimulator, .watchOSSimulator:
                return simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID })?.name ?? "No sim"
            }
        }()
                let simIcon: String = {
            switch localRunDestination {
            case .macOS: return "laptopcomputer"
            case .iOSDevice:
                if let d = devicesForToolbar.first(where: { $0.id == selectedSimulatorID }) {
                    return d.menuSymbolName
                }
                return "iphone.gen3"
            case .watchOSSimulator: return "applewatch"
            case .iOSSimulator: return "iphone"
            }
        }()

        let projectRoot = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 0) {
                contextProjectTitle(folderShort: folderShort, path: projectRoot)

                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prov.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(modelLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(minWidth: 120, alignment: .leading)
                .padding(.trailing, 20)

                HStack(spacing: 10) {
                    contextRunPill(icon: simIcon, title: "Run target", value: simLabel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    private func contextProjectTitle(folderShort: String, path: String) -> some View {
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(folderShort)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.trailing, 4)
        .contextMenu {
            Button("Reveal in Finder") {
                guard exists else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(!exists)
        }
    }

    private func contextRunPill(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(buildChatDisplayRows(from: viewModel.items)) { row in
                        Group {
                            switch row {
                            case .user(let item):
                                HStack(alignment: .top, spacing: 0) {
                                    Spacer(minLength: 0)
                                    ChatItemView(item: item)
                                }
                                .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            case .working(let item):
                                TransientWorkingRow(item: item, reduceMotion: reduceMotion)
                                    .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .assistantTurn(_, let items):
                                AssistantTurnCard(items: items, reduceMotion: reduceMotion)
                                    .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.thinMaterial.opacity(0.45))
            .onChange(of: viewModel.changeCount) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("bottom")
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 10)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            input += "\n"
                            return .handled
                        }
                        sendMessage()
                        return .handled
                    }

                Button(action: {
                    if hasInputText {
                        sendMessage()
                    } else {
                        viewModel.stop()
                    }
                }) {
                    Image(systemName: viewModel.isRunning && !hasInputText ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .padding(.trailing, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

            Text(composerTips[composerTipIndex % composerTips.count])
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
                .opacity(latticeShowComposerTips ? 1 : 0)
                .accessibilityHidden(!latticeShowComposerTips)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .opacity(canSend || viewModel.isRunning ? 1 : 0.55)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            composerTipIndex += 1
        }
    }

    private var hasInputText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !activeAPIKey.isEmpty && (hasInputText || viewModel.isRunning)
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        viewModel.send(text, apiKey: activeAPIKey, context: chatContext)
    }

    private func copyTextAndToast(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyToastText = toast
        withAnimation(.easeOut(duration: 0.18)) {
            showCopyToast = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeIn(duration: 0.18)) {
                showCopyToast = false
            }
        }
    }

    private var canLocalBuildAndRun: Bool {
        let root = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !isDirectRunInProgress else { return false }
        switch localRunDestination {
        case .macOS:
            return true
        case .iOSSimulator, .watchOSSimulator, .iOSDevice:
            return !selectedSimulatorID.isEmpty
        }
    }

    private func runOnSimulatorDirect() {
        let root = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            directRunBanner = "Pick a project folder first."
            directRunBannerIsError = true
            return
        }
        let dest = localRunDestination
        if dest != .macOS, selectedSimulatorID.isEmpty {
            directRunBanner = dest == .iOSDevice
                ? "Select a connected iPhone/iPad from the toolbar menu."
                : "Select a simulator from the toolbar menu (or choose My Mac in Settings)."
            directRunBannerIsError = true
            return
        }
        guard !isDirectRunInProgress else { return }

        let projectURL = URL(fileURLWithPath: root)
        let udid = selectedSimulatorID.isEmpty ? nil : selectedSimulatorID

        isDirectRunInProgress = true
        directRunBanner = nil

        Task { @MainActor in
            defer { isDirectRunInProgress = false }
            do {
                let msg = try await SimulatorBuildRunner.run(
                    projectRoot: projectURL,
                    destination: dest,
                    simulatorUDID: udid,
                    buildInfo: nil,
                    developmentTeam: resolvedDevelopmentTeam,
                    bundleIdentifierOverride: latticeBundleIdentifierOverride,
                    buildLogHandler: { log in
                        consoleStore.append(log, category: "xcodebuild", projectPath: root)
                    }
                )
                directRunBanner = msg
                directRunBannerIsError = false
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                consoleStore.appendLine(text, category: "build-error", projectPath: root)
                directRunBanner = text
                directRunBannerIsError = true
            }
        }
    }

    private func refreshProjectDerivedSettings() {
        let root = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let projectURL = URL(fileURLWithPath: root)
        Task { @MainActor in
            do {
                let supported = try await SimulatorBuildRunner.detectSupportedRunDestinations(
                    projectRoot: projectURL,
                    buildInfo: nil
                )
                supportedRunDestinations = supported
                if !supported.contains(localRunDestination) {
                    if supported.contains(.iOSSimulator) {
                        latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSSimulator.rawValue
                    } else if supported.contains(.watchOSSimulator) {
                        latticeLocalRunDestinationRaw = LatticeLocalRunDestination.watchOSSimulator.rawValue
                    } else if supported.contains(.iOSDevice) {
                        latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSDevice.rawValue
                    } else {
                        latticeLocalRunDestinationRaw = LatticeLocalRunDestination.macOS.rawValue
                    }
                    selectedSimulatorID = ""
                }
            } catch {
                supportedRunDestinations = .allRunDestinations
            }
            do {
                discoveredDevelopmentTeams = try await SimulatorBuildRunner.discoverDevelopmentTeams(
                    projectRoot: projectURL,
                    buildInfo: nil
                )
            } catch {
                discoveredDevelopmentTeams = []
            }
        }
    }

    private var selectedRunTargetContext: String? {
        if localRunDestination == .iOSDevice,
           let device = simulatorStore.connectedDevices.first(where: { $0.id == selectedSimulatorID }) {
            let kind = device.isAppleWatch ? "watchOS Device" : "iOS Device"
            return """
            Destination Kind: \(kind)
            Device UDID: \(device.id)
            Device Name: \(device.name)
            OS: \(device.platform)
            """
        }
        if localRunDestination == .macOS {
            return "Destination Kind: macOS\nDestination: My Mac"
        }
        guard let simulator = simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID }) else {
            return nil
        }
        return """
        Destination Kind: Simulator
        UDID: \(simulator.id)
        Name: \(simulator.name)
        Runtime: \(simulator.runtime)
        """
    }

    private var chatContext: ChatContext {
        ChatContext(
            runTarget: selectedRunTargetContext,
            projectPath: selectedProjectPath.isEmpty ? nil : selectedProjectPath,
            model: selectedModel,
            provider: selectedProvider,
            zaiUseCodingEndpoint: zaiUseCodingEndpoint,
            buildInfo: nil,
            bundleIdentifierOverride: latticeBundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : latticeBundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            developmentTeam: resolvedDevelopmentTeam
        )
    }

    private func buildChatDisplayRows(from items: [ChatItem]) -> [ChatDisplayRow] {
        var rows: [ChatDisplayRow] = []
        var i = 0
        while i < items.count {
            switch items[i].kind {
            case .user:
                rows.append(.user(items[i]))
                i += 1
            case .working:
                rows.append(.working(items[i]))
                i += 1
            case .assistant, .tool, .reasoning:
                let anchorId = items[i].id
                var chunk: [ChatItem] = []
                groupLoop: while i < items.count {
                    switch items[i].kind {
                    case .user, .working:
                        break groupLoop
                    case .assistant, .tool, .reasoning:
                        if case .reasoning(let text, _) = items[i].kind,
                           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            i += 1
                            continue
                        }
                        if case .tool(let name, let input, let output, _, _) = items[i].kind {
                            let isEmptyTool = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && ((output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if isEmptyTool {
                                i += 1
                                continue
                            }
                        }
                        chunk.append(items[i])
                        i += 1
                    }
                }
                rows.append(.assistantTurn(anchorId: anchorId, items: chunk))
            }
        }
        return rows
    }
}

private struct BuildBannerCopyButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private func normalizeAssistantText(_ raw: String) -> String {
    var s = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "```", with: "")
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")

    while s.contains("\n\n\n") {
        s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    if let headingRe = try? NSRegularExpression(pattern: #"(?m)^\s*#{1,6}\s*"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = headingRe.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
    if let bulletRe = try? NSRegularExpression(pattern: #"(?m)^\s*[-*+]\s+"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = bulletRe.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
    if let quoteRe = try? NSRegularExpression(pattern: #"(?m)^\s*>\s?"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = quoteRe.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct MarkdownBlock: View {
    let text: String
    var isStreaming: Bool = false
    var multilineTextAlignment: TextAlignment = .leading

    var body: some View {
        Group {
            if text.isEmpty {
                if isStreaming {
                    ProgressView().scaleEffect(0.75)
                }
            } else if isStreaming {
                Text(normalizeAssistantText(text))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .multilineTextAlignment(multilineTextAlignment)
                    .lineSpacing(4)
            } else {
                Text(normalizeAssistantText(text))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .lineSpacing(5)
                    .multilineTextAlignment(multilineTextAlignment)
            }
        }
    }

    private var frameAlignment: Alignment {
        switch multilineTextAlignment {
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}

private enum AssistantTurnPiece: Identifiable {
    case reasoning(ChatItem)
    case assistant(ChatItem)
    case tools([ChatItem])

    var id: String {
        switch self {
        case .reasoning(let item):
            return "r-\(item.id.uuidString)"
        case .assistant(let item):
            return "a-\(item.id.uuidString)"
        case .tools(let items):
            return "t-\(items.map(\.id.uuidString).joined(separator: "-"))"
        }
    }
}

private func assistantTurnPieces(from items: [ChatItem]) -> [AssistantTurnPiece] {
    var pieces: [AssistantTurnPiece] = []
    var i = 0
    while i < items.count {
        let item = items[i]
        switch item.kind {
        case .user, .working:
            i += 1
        case .reasoning:
            pieces.append(.reasoning(item))
            i += 1
        case .assistant:
            pieces.append(.assistant(item))
            i += 1
        case .tool:
            var run: [ChatItem] = []
            while i < items.count {
                guard case .tool = items[i].kind else { break }
                run.append(items[i])
                i += 1
            }
            if !run.isEmpty {
                pieces.append(.tools(run))
            }
        }
    }
    return pieces
}

/// One-line subtitle for a tool row (paths → filenames, long bash → clipped).
private func latticeFriendlyToolSubtitle(name: String, input: String) -> String {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "" }
    if name == "write_file" || name == "read_file" {
        let path: String = {
            if t.hasPrefix("->") {
                return String(t.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return t
        }()
        let base = (path as NSString).lastPathComponent
        if !base.isEmpty, base != "/", base != "." { return base }
    }
    let oneLine = t.replacingOccurrences(of: "\n", with: " ")
    if oneLine.count > 54 { return String(oneLine.prefix(51)) + "…" }
    return oneLine
}

private func latticeToolRunSummaryLine(tools: [ChatItem]) -> String {
    var parts: [String] = []
    for item in tools.prefix(4) {
        guard case .tool(let name, let input, _, _, _) = item.kind else { continue }
        let sub = latticeFriendlyToolSubtitle(name: name, input: input)
        if sub.isEmpty {
            parts.append(name)
        } else {
            parts.append("\(name) \(sub)")
        }
    }
    let head = parts.joined(separator: " · ")
    let extra = tools.count - parts.count
    if extra > 0 {
        return head.isEmpty ? "+\(extra)" : "\(head)  +\(extra)"
    }
    return head
}

/// Assistant markdown: its own light surface so long replies are not one giant slab with tools.
private struct AssistantProseCard: View {
    let text: String
    let streaming: Bool
    var reduceMotion: Bool = false
    /// When nested inside `AssistantTurnCard`, outer chrome is handled by the turn container.
    var unifiedTurn: Bool = false
    @State private var streamPulse = false

    private var isErrorText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("error:")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isErrorText {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            MarkdownBlock(text: text, isStreaming: streaming)
            if streaming, !text.isEmpty {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 22, height: 4)
                        .opacity(reduceMotion ? 1 : (streamPulse ? 0.35 : 1))
                        .animation(
                            reduceMotion ? .default : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                            value: streamPulse
                        )
                }
                .onAppear { streamPulse = true }
            }
        }
        .padding(.horizontal, unifiedTurn ? 2 : 11)
        .padding(.vertical, unifiedTurn ? 6 : 9)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .background(proseBackground)
        .overlay(proseStroke)
    }

    @ViewBuilder
    private var proseBackground: some View {
        if unifiedTurn {
            if isErrorText {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            } else {
                Color.clear
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isErrorText ? Color.orange.opacity(0.08) : Color.primary.opacity(0.045))
        }
    }

    @ViewBuilder
    private var proseStroke: some View {
        if unifiedTurn {
            if isErrorText {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            } else {
                EmptyView()
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isErrorText ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct TransientWorkingRow: View {
    let item: ChatItem
    var reduceMotion: Bool = false
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.14), in: Circle())
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            VStack(alignment: .leading, spacing: 4) {
                Text("Thinking")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 34, height: 5)
                    .opacity(reduceMotion ? 1 : (pulse ? 0.35 : 1))
                    .animation(
                        reduceMotion ? .default : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .id(item.id)
        .onAppear { pulse = true }
    }
}

private struct ReasoningCollapsibleCard: View {
    let text: String
    let streaming: Bool
    var reduceMotion: Bool = false
    var unifiedTurn: Bool = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack {
                    Label(streaming ? "Thinking" : "Thought", systemImage: "brain.head.profile")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if streaming {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded || streaming {
                if text.isEmpty, streaming {
                    Text("…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(normalizeAssistantText(text))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(4)
                }
            }
        }
        .padding(.horizontal, unifiedTurn ? 2 : 10)
        .padding(.vertical, unifiedTurn ? 6 : 8)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .background(reasoningBackground)
        .overlay(reasoningStroke)
        .onAppear {
            if streaming { expanded = true }
        }
        .onChange(of: streaming) { _, isStreaming in
            if isStreaming { expanded = true }
        }
    }

    @ViewBuilder
    private var reasoningBackground: some View {
        if unifiedTurn {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        }
    }

    @ViewBuilder
    private var reasoningStroke: some View {
        if unifiedTurn {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

/// Secondary panel so tool noise reads as “metadata”, not the main message.
private struct LatticeToolActivitySection<Content: View>: View {
    var unifiedTurn: Bool = false
    private let content: () -> Content

    init(unifiedTurn: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.unifiedTurn = unifiedTurn
        self.content = content
    }

    var body: some View {
        Group {
            if unifiedTurn {
                content()
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content()
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
                    )
            }
        }
    }
}

/// One assistant “turn”: prose, reasoning, and tools in one column.
private struct AssistantTurnCard: View {
    let items: [ChatItem]
    var reduceMotion: Bool = false

    private var pieces: [AssistantTurnPiece] {
        assistantTurnPieces(from: items)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
                    turnPiece(piece)
                    if index < pieces.count - 1 {
                        Divider()
                            .opacity(0.28)
                            .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.17), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func turnPiece(_ piece: AssistantTurnPiece) -> some View {
        switch piece {
        case .reasoning(let item):
            if case .reasoning(let text, let streaming) = item.kind {
                ReasoningCollapsibleCard(text: text, streaming: streaming, reduceMotion: reduceMotion, unifiedTurn: true)
            }
        case .assistant(let item):
            if case .assistant(let text, let streaming) = item.kind {
                AssistantProseCard(text: text, streaming: streaming, reduceMotion: reduceMotion, unifiedTurn: true)
            }
        case .tools(let toolItems):
            LatticeToolActivitySection(unifiedTurn: true) {
                if toolItems.count >= latticeToolRunBatchThreshold {
                    ToolActivityBatchView(tools: toolItems, reduceMotion: reduceMotion)
                } else {
                    ForEach(toolItems) { t in
                        if case .tool(let name, let input, let output, let isError, let isRunning) = t.kind {
                            ToolActivityRow(
                                stableId: t.id,
                                name: name,
                                input: input,
                                output: output,
                                isError: isError,
                                isRunning: isRunning,
                                reduceMotion: reduceMotion
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Collapses many consecutive tool steps into one row; expand to see each `ToolActivityRow`.
private struct ToolActivityBatchView: View {
    let tools: [ChatItem]
    var reduceMotion: Bool = false
    @State private var expanded = false

    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    private var effectiveReduceMotion: Bool { reduceMotion || envReduceMotion }

    private var expandAnimation: Animation {
        effectiveReduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    private var stepCount: Int { tools.count }

    private var anyRunning: Bool {
        tools.contains { if case .tool(_, _, _, _, let running) = $0.kind { return running }; return false }
    }

    private var anyError: Bool {
        tools.contains { if case .tool(_, _, _, let err, _) = $0.kind { return err }; return false }
    }

    private var errorCount: Int {
        tools.reduce(into: 0) { n, item in
            if case .tool(_, _, _, let err, _) = item.kind, err { n += 1 }
        }
    }

    private var summaryLine: String {
        let s = latticeToolRunSummaryLine(tools: tools)
        return s.isEmpty ? "Tap to expand" : s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "square.stack.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(stepCount) steps")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                            if anyError {
                                Text(errorCount == 1 ? "1 failed" : "\(errorCount) failed")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(summaryLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if anyRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { t in
                        if case .tool(let name, let input, let output, let isError, let isRunning) = t.kind {
                            ToolActivityRow(
                                stableId: t.id,
                                name: name,
                                input: input,
                                output: output,
                                isError: isError,
                                isRunning: isRunning,
                                reduceMotion: effectiveReduceMotion
                            )
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
        .padding(4)
        .animation(expandAnimation, value: expanded)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(anyError ? 0.28 : 0.14), lineWidth: 1)
        )
        .id(tools.map(\.id.uuidString).joined(separator: "-"))
    }
}

/// Single tool step: tight row, disclosure expands only this row (no shared flex / lazy height coupling).
private struct ToolActivityRow: View {
    let stableId: UUID
    let name: String
    let input: String
    let output: String?
    let isError: Bool
    let isRunning: Bool
    var reduceMotion: Bool = false

    @State private var showOutput = false

    private var rowExpandAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.9)
    }

    private var displayInput: String {
        latticeFriendlyToolSubtitle(name: name, input: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard let out = output, !out.isEmpty, !isRunning else { return }
                showOutput.toggle()
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: toolIcon)
                        .font(.caption2)
                        .foregroundStyle(isError ? Color.orange.opacity(0.95) : Color.secondary)
                        .frame(width: 14, alignment: .center)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !displayInput.isEmpty {
                            Text(displayInput)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if output != nil {
                        Image(systemName: showOutput ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRunning || (output?.isEmpty ?? true))

            if showOutput, let out = output, !out.isEmpty {
                Group {
                    Divider()
                        .opacity(0.35)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            Text(out)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(isError ? Color.orange : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10)
                                .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 140, alignment: .top)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(out, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                        .help("Copy output")
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
        .animation(rowExpandAnimation, value: showOutput)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isError ? Color.orange.opacity(0.32) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .id(stableId)
    }

    private var toolIcon: String {
        switch name {
        case "bash": return "terminal"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Chat item views

struct ChatItemView: View {
    let item: ChatItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text, reduceMotion: reduceMotion)
        case .reasoning(let text, let isStreaming):
            ReasoningCollapsibleCard(text: text, streaming: isStreaming, reduceMotion: reduceMotion)
        case .working:
            TransientWorkingRow(item: item, reduceMotion: reduceMotion)
        case .assistant(let text, let isStreaming):
            AssistantBubble(text: text, isStreaming: isStreaming, reduceMotion: reduceMotion)
        case .tool(let name, let input, let output, let isError, let isRunning):
            ToolCard(name: name, input: input, output: output, isError: isError, isRunning: isRunning)
        }
    }
}

struct UserBubble: View {
    let text: String
    var reduceMotion: Bool = false

    var body: some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .lineSpacing(5)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(reduceMotion ? 0 : 0.12), radius: 6, y: 2)
            .frame(minWidth: 0, maxWidth: latticeUserBubbleMaxWidth, alignment: .trailing)
    }
}

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool
    var reduceMotion: Bool = false
    @State private var streamPulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isStreaming && !reduceMotion)

            VStack(alignment: .leading, spacing: 6) {
                MarkdownBlock(text: text, isStreaming: isStreaming)
                if isStreaming, !text.isEmpty {
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: 28, height: 5)
                            .opacity(reduceMotion ? 1 : (streamPulse ? 0.35 : 1))
                            .animation(
                                reduceMotion ? .default : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                                value: streamPulse
                            )
                        Text("Streaming")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .onAppear {
                        streamPulse = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )

            Spacer(minLength: 16)
        }
    }
}

struct ToolCard: View {
    let name: String
    let input: String
    let output: String?
    let isError: Bool
    let isRunning: Bool

    @State private var isExpanded = false
    @State private var didApplyLongOutputCollapse = false
    @State private var runStart: Date?
    @State private var finishedDuration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: toolIcon)
                            .foregroundStyle(isError ? .red : .secondary)
                            .frame(width: 16)

                        Text(name)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)

                        if !input.isEmpty {
                            Text(input)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let d = finishedDuration, !isRunning {
                            Text(String(format: "%.1fs", d))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 8)

                        if isRunning {
                            ProgressView().scaleEffect(0.6)
                        } else if output != nil {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded, let out = output, !out.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(out, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .help("Copy output")
                }
            }
            .background(.thinMaterial.opacity(0.65))

            if isExpanded, let out = output, !out.isEmpty {
                Divider()
                ScrollView {
                    Text(out)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 240, alignment: .top)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isError ? Color.red.opacity(0.45) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        )
        .onAppear {
            if !didApplyLongOutputCollapse {
                didApplyLongOutputCollapse = true
                if (output?.count ?? 0) > 400 {
                    isExpanded = false
                }
            }
        }
        .onChange(of: isRunning) { _, running in
            if running {
                runStart = Date()
                finishedDuration = nil
            } else if let start = runStart {
                finishedDuration = Date().timeIntervalSince(start)
                runStart = nil
            }
        }
    }

    private var toolIcon: String {
        switch name {
        case "bash":           return "terminal"
        case "read_file":      return "doc.text"
        case "write_file":     return "square.and.pencil"
        default:               return "wrench"
        }
    }
}

// MARK: - Supporting views

struct ProjectInspectorView: View {
    @Binding var selectedProjectPath: String
    @Binding var developmentTeam: String
    @Binding var bundleIdentifierOverride: String
    let discoveredDevelopmentTeams: [String]
    @Binding var showSigningHelpPopover: Bool

    @State private var openingXcode = false
    @State private var showXcodeAlert = false
    @State private var xcodeAlertMessage = ""

    @State private var identityProductName = ""
    @State private var identityDisplayName = ""
    @State private var identityMarketingVersion = ""
    @State private var identityBuildNumber = ""
    @State private var identityLoading = false
    @State private var identityApplyBusy = false
    @State private var identityError: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 10) {
                    Button("Choose Folder") { chooseProjectFolder() }
                    if !selectedProjectPath.isEmpty {
                        Button("Clear") { selectedProjectPath = "" }
                            .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await openProjectInXcode() }
                    } label: {
                        Group {
                            if openingXcode {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Open in Xcode", systemImage: "hammer")
                            }
                        }
                        .frame(minWidth: openingXcode ? 24 : nil)
                    }
                    .disabled(selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || openingXcode)
                    .help("Opens the same .xcworkspace or .xcodeproj Build & Run uses.")
                }

                if !selectedProjectPath.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Selected path")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(selectedProjectPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 2)
                }
            } header: {
                Text("Project")
            } footer: {
                Text("⌘R builds this folder. Pick the simulator or device in the toolbar; API keys stay under Account.")
            }

            Section {
                if identityLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading app identity…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Project name (PRODUCT_NAME)", text: $identityProductName)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name", text: $identityDisplayName)
                    .textFieldStyle(.roundedBorder)
                TextField("Version", text: $identityMarketingVersion)
                    .textFieldStyle(.roundedBorder)
                TextField("Build", text: $identityBuildNumber)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await applyAppIdentity() }
                } label: {
                    if identityApplyBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply to Xcode project")
                    }
                }
                .disabled(
                    identityApplyBusy
                        || selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                if let identityError {
                    Text(identityError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("App identity")
            } footer: {
                Text("Updates build settings for the main application target in project.pbxproj.")
            }

            Section {
                if !discoveredDevelopmentTeams.isEmpty {
                    Picker("Detected teams", selection: $developmentTeam) {
                        Text("Manual entry").tag("")
                        ForEach(discoveredDevelopmentTeams, id: \.self) { team in
                            Text(team).tag(team)
                        }
                    }
                    .pickerStyle(.menu)
                }
                TextField("Team ID", text: $developmentTeam)
                    .textFieldStyle(.roundedBorder)
                    .help("10-character Apple Developer Team ID")
                TextField("Bundle ID override", text: $bundleIdentifierOverride)
                    .textFieldStyle(.roundedBorder)
                    .help("Optional PRODUCT_BUNDLE_IDENTIFIER for Build & Run")
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Signing")
                    Button {
                        showSigningHelpPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSigningHelpPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Signing")
                                .font(.headline)
                            Text("If nothing appears under Detected teams, sign in under Xcode → Settings → Accounts.")
                            Text("Team ID is the 10-character value from Apple Developer membership or Xcode’s team list.")
                            Text("For a physical device: unlock it, trust this Mac, and enable Developer Mode.")
                        }
                        .font(.callout)
                        .padding()
                        .frame(width: 340, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Overrides DEVELOPMENT_TEAM and bundle ID when set; otherwise Account’s global Team ID applies.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 6)
        .alert("Could not open in Xcode", isPresented: $showXcodeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(xcodeAlertMessage)
        }
        .onAppear { loadAppIdentity() }
        .onChange(of: selectedProjectPath) { _, _ in
            loadAppIdentity()
        }
    }

    private func loadAppIdentity() {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            identityProductName = ""
            identityDisplayName = ""
            identityMarketingVersion = ""
            identityBuildNumber = ""
            identityError = nil
            return
        }
        identityLoading = true
        identityError = nil
        Task {
            do {
                let id = try await ProjectAppIdentityEditor.load(projectRoot: URL(fileURLWithPath: path))
                await MainActor.run {
                    identityProductName = id.productName
                    identityDisplayName = id.displayName
                    identityMarketingVersion = id.marketingVersion
                    identityBuildNumber = id.buildNumber
                    identityLoading = false
                }
            } catch {
                await MainActor.run {
                    identityError = error.localizedDescription
                    identityLoading = false
                }
            }
        }
    }

    private func applyAppIdentity() async {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        identityApplyBusy = true
        identityError = nil
        defer { identityApplyBusy = false }
        let identity = ProjectAppIdentity(
            productName: identityProductName,
            displayName: identityDisplayName,
            marketingVersion: identityMarketingVersion,
            buildNumber: identityBuildNumber
        )
        do {
            try await ProjectAppIdentityEditor.save(projectRoot: URL(fileURLWithPath: path), identity: identity)
            loadAppIdentity()
        } catch {
            identityError = error.localizedDescription
        }
    }

    private func openProjectInXcode() async {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        openingXcode = true
        defer { openingXcode = false }
        do {
            try await SimulatorBuildRunner.openProjectInXcode(projectRoot: URL(fileURLWithPath: path))
        } catch {
            xcodeAlertMessage = error.localizedDescription
            showXcodeAlert = true
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if !selectedProjectPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedProjectPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            selectedProjectPath = url.path
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            simulatorStore: SimulatorStore(),
            generationState: LatticeGenerationState(),
            consoleStore: LatticeConsoleStore()
        )
    }
}

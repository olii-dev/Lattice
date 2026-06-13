import AppKit
import Combine
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transcript layout (reading column: assistant leading, user trailing)

/// Column width for transcript; centered in the window; rows align content inside it.
private let latticeTranscriptColumnMaxWidth: CGFloat = 660
private let latticeUserBubbleMaxWidth: CGFloat = 348
/// Assistant markdown reads best a bit narrower than the full column.
private let latticeAssistantProseMaxWidth: CGFloat = 520
private let latticeAttachmentTileWidth: CGFloat = 124
private let latticeAttachmentTileHeight: CGFloat = 88
private let latticeComposerAttachmentWidth: CGFloat = 116
private let latticeComposerAttachmentHeight: CGFloat = 78
private let latticeSingleMessageAttachmentWidth: CGFloat = 228
private let latticeSingleMessageAttachmentHeight: CGFloat = 154

// MARK: - Shared UI tokens

private enum LatticeSurfaceTokens {
    static let cornerSmall: CGFloat = 10
    static let cornerMedium: CGFloat = 14
    static let cornerLarge: CGFloat = 18
    /// Softer “voice assistant” transcript cards (Dribbble-style glass bubbles).
    static let cornerTranscript: CGFloat = 22
    static let shellStrokeOpacity: CGFloat = 0.12
    static let shellShadowOpacity: CGFloat = 0.10
    static let elevatedFillOpacity: CGFloat = 0.06
    static let focusFillOpacity: CGFloat = 0.12
}

private struct LatticeElevatedCardModifier: ViewModifier {
    let radius: CGFloat
    let strokeOpacity: CGFloat
    let shadowOpacity: CGFloat

    init(
        radius: CGFloat = LatticeSurfaceTokens.cornerMedium,
        strokeOpacity: CGFloat = LatticeSurfaceTokens.shellStrokeOpacity,
        shadowOpacity: CGFloat = LatticeSurfaceTokens.shellShadowOpacity
    ) {
        self.radius = radius
        self.strokeOpacity = strokeOpacity
        self.shadowOpacity = shadowOpacity
    }

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 2)
    }
}

private extension View {
    func latticeElevatedCard(
        radius: CGFloat = LatticeSurfaceTokens.cornerMedium,
        strokeOpacity: CGFloat = LatticeSurfaceTokens.shellStrokeOpacity,
        shadowOpacity: CGFloat = LatticeSurfaceTokens.shellShadowOpacity
    ) -> some View {
        modifier(
            LatticeElevatedCardModifier(
                radius: radius,
                strokeOpacity: strokeOpacity,
                shadowOpacity: shadowOpacity
            )
        )
    }
}

/// Consecutive tool runs this long collapse into one disclosure by default.
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

struct LatticeImageAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    let path: String
    let fileName: String
    let mimeType: String

    nonisolated init(id: UUID = UUID(), path: String, fileName: String, mimeType: String) {
        self.id = id
        self.path = path
        self.fileName = fileName
        self.mimeType = mimeType
    }

    nonisolated init?(url: URL) {
        guard url.isFileURL else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        guard mimeType.hasPrefix("image/") else { return nil }
        self.init(path: path, fileName: url.lastPathComponent, mimeType: mimeType)
    }
}

private extension NSImage {
    nonisolated var latticePNGData: Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    var latticePixelSize: CGSize {
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return size
    }

    func latticeCropped(to normalizedRect: CGRect) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let clamped = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0.01, clamped.height > 0.01 else { return nil }

        let cropRect = CGRect(
            x: clamped.minX * width,
            y: (1 - clamped.maxY) * height,
            width: clamped.width * width,
            height: clamped.height * height
        ).integral

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    func latticeAnnotated(with strokes: [[CGPoint]], lineWidth: CGFloat = 8) -> NSImage? {
        guard let base = latticePNGData,
              let bitmap = NSBitmapImageRep(data: base) else { return nil }

        let output = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        output.lockFocus()
        defer { output.unlockFocus() }

        NSImage(data: base)?.draw(in: NSRect(origin: .zero, size: output.size))

        let scale = min(output.size.width, output.size.height)
        NSColor.systemPink.setStroke()
        for stroke in strokes where stroke.count >= 2 {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = max(2, lineWidth * scale)
            for (index, point) in stroke.enumerated() {
                let mapped = CGPoint(x: point.x * output.size.width, y: (1 - point.y) * output.size.height)
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.line(to: mapped)
                }
            }
            path.stroke()
        }

        return output
    }
}

extension LatticeImageAttachment {
    nonisolated static func fromClipboardImage(_ image: NSImage, suggestedName: String? = nil) -> LatticeImageAttachment? {
        guard let pngData = image.latticePNGData else { return nil }
        let fileName = (suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Pasted Image.png"
        return writeTemporaryImageData(pngData, fileName: fileName, mimeType: "image/png")
    }

    nonisolated static func fromImageData(_ data: Data, suggestedName: String? = nil, mimeType: String? = nil) -> LatticeImageAttachment? {
        let resolvedMimeType = mimeType?.lowercased() ?? "image/png"
        if resolvedMimeType == "image/png" || resolvedMimeType == "image/jpeg" || resolvedMimeType == "image/jpg" {
            let fileName = (suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultFileName(forMimeType: resolvedMimeType)
            return writeTemporaryImageData(data, fileName: fileName, mimeType: resolvedMimeType == "image/jpg" ? "image/jpeg" : resolvedMimeType)
        }

        guard let image = NSImage(data: data) else { return nil }
        return fromClipboardImage(image, suggestedName: suggestedName)
    }

    nonisolated static func fromEditedImage(_ image: NSImage, originalName: String) -> LatticeImageAttachment? {
        guard let pngData = image.latticePNGData else { return nil }
        let stem = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        let fileName = stem.isEmpty ? "Edited Image.png" : "\(stem)-edited.png"
        return writeTemporaryImageData(pngData, fileName: fileName, mimeType: "image/png")
    }

    private nonisolated static func writeTemporaryImageData(_ data: Data, fileName: String, mimeType: String) -> LatticeImageAttachment? {
        let sanitizedName = fileName.replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-image-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
        do {
            try data.write(to: target, options: .atomic)
            return LatticeImageAttachment(path: target.path, fileName: sanitizedName, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private nonisolated static func defaultFileName(forMimeType mimeType: String) -> String {
        let ext: String
        switch mimeType {
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "png"
        }
        return "Pasted Image.\(ext)"
    }
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
    let projectSummary: LatticeProjectSummary?

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
        lhs.developmentTeam == rhs.developmentTeam &&
        lhs.projectSummary == rhs.projectSummary
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
            [Active Bundle Identifier]
            \(bid)
            """)
        }
        if let team = developmentTeam, !team.isEmpty {
            sections.append("""
            [Development Team]
            \(team)
            """)
        }
        if let projectSummary, !projectSummary.isEmpty {
            var summarySection = "[Project Product Summary]"
            if let appName = projectSummary.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
                summarySection += "\n- App name: \(appName)"
            }
            if let concept = projectSummary.concept?.trimmingCharacters(in: .whitespacesAndNewlines), !concept.isEmpty {
                summarySection += "\n- App concept: \(concept)"
            }
            let surfaces = projectSummary.surfaces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !surfaces.isEmpty {
                summarySection += "\n- App surfaces: \(surfaces.joined(separator: ", "))"
            }
            if let navigation = projectSummary.navigation?.trimmingCharacters(in: .whitespacesAndNewlines), !navigation.isEmpty {
                summarySection += "\n- App navigation: \(navigation)"
            }
            if let designDirection = projectSummary.designDirection?.trimmingCharacters(in: .whitespacesAndNewlines), !designDirection.isEmpty {
                summarySection += "\n- Design direction: \(designDirection)"
            }
            let openIssues = (projectSummary.openIssues ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !openIssues.isEmpty {
                summarySection += "\n- Open issues: \(openIssues.joined(separator: ", "))"
            }
            sections.append(summarySection)
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

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    /// Bumped only when the transcript should pin to the bottom (streaming, tools, send). Not used for unrelated layout.
    @Published private(set) var transcriptScrollToBottomToken: UInt = 0
    /// Parsed from the latest finalized assistant reply (Bundle / Team / version lines).
    @Published private(set) var pendingInspectorHints: AssistantInspectorHints?
    @Published private(set) var projectSummary: LatticeProjectSummary?
    @Published private(set) var livePhase: LatticeDirectorPhase?

    private let service = LLMService()
    private let executor = ToolExecutor()
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
            LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: oid)
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

        LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: restoreRevision)
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

    private func noteTranscriptScrollIntent() {
        requestTranscriptScrollToBottom(immediate: false)
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
            LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: root, revision: oid)
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
                let (output, isError) = await executor.execute(name: toolName, input: input)
                if toolName == "write_file", let u = writeUndo, !isError {
                    burstFileUndos.append(u)
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

                toolResults.append(toolResultMessage(
                    toolUseId: toolId, content: output, isError: isError
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
        case "open_spec_docs": return obj["change_name"] as? String ?? ""
        default:               return json
        }
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

// MARK: - History restore UI
// TODO(lattice-history-ui): Re-enable and polish HistoryRestoreSheet in toolbar once restore behavior is fully validated end-to-end.
private struct HistoryRestoreSheet: View {
    /// Chronological checkpoints (oldest → newest).
    let checkpoints: [LatticeChatRestorePointHeader]
    let isBusy: Bool
    /// When `targetId` is nil, callers should reset to an empty chat for this project.
    /// `restoredPrompt` is the checkpoint message text the user selected.
    let onRestore: (_ selectedId: UUID, _ chatTargetId: UUID?, _ restoredPrompt: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var showConfirm = false

    private var relative: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }

    private var dateFmt: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if checkpoints.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 34, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tertiary)
                        Text("No checkpoints yet")
                            .font(.headline)
                        Text("Checkpoints appear after each finished reply. Send a message, wait for the agent to finish, then open History again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 40)
                } else {
                    List(selection: $selectedID) {
                        Section {
                            ForEach(checkpoints.reversed()) { h in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(h.userLine)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("\(relative.localizedString(for: h.createdAt, relativeTo: Date())) • \(dateFmt.string(from: h.createdAt))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .contentShape(Rectangle())
                                .tag(h.id)
                                .onTapGesture { selectedID = h.id }
                            }
                        } footer: {
                            Text("Restoring resets the repo (when available) and model context to that moment. The selected checkpoint and any newer checkpoints are removed.")
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showConfirm = true
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isBusy || selectedID == nil)
                }
            }
            .confirmationDialog(
                "Restore to this checkpoint?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore", role: .destructive) {
                    guard let selectedID else { return }
                    let restoredPrompt = checkpoints.first(where: { $0.id == selectedID })?.userText
                        ?? checkpoints.first(where: { $0.id == selectedID })?.userLine
                        ?? ""
                    if let idx = checkpoints.firstIndex(where: { $0.id == selectedID }) {
                        let chatTarget = (idx == 0) ? selectedID : checkpoints[idx - 1].id
                        onRestore(selectedID, chatTarget, restoredPrompt)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let selectedID,
                   let selected = checkpoints.first(where: { $0.id == selectedID }) {
                    Text("After: “\(selected.userLine)”")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
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
    @Environment(\.colorScheme) private var colorScheme

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
    @AppStorage("latticeBundleIdentifierOverridesJSON") private var latticeBundleIdentifierOverridesJSON = "{}"
    @State private var input = ""
    @State private var composerHeight: CGFloat = 42
    @State private var showProjectPanel = false
    @State private var showProjectHub = false
    @State private var composerImageAttachments: [LatticeImageAttachment] = []
    @State private var selectedImagePreview: LatticeImageAttachment?
    @State private var composerEditingAttachment: LatticeImageAttachment?
    @State private var draggingComposerAttachmentID: UUID?
    @State private var isComposerDropTarget = false
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
    @State private var latticeBundleIdentifierOverride = ""
    @State private var resolvedProjectBundleIdentifier = ""

    private let composerTips = [
        "Shift+Return for newline",
        "Return sends the message",
        "Ask for screens, flows, polish, and native structure",
    ]

    @State private var showConsoleSheet = false
    @State private var consoleSearch = ""
    @State private var sidebarLayoutScrollToken: UInt = 0

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

    private var selectedProviderOption: LLMProvider {
        LLMProvider(rawValue: selectedProvider) ?? .anthropic
    }

    private var selectedModelSupportsImages: Bool {
        selectedProviderOption.models.first(where: { $0.id == selectedModel })?.supportsImages ?? false
    }

    private func assistantTurnRestoreActions(for rows: [ChatDisplayRow]) -> [UUID: (checkpointId: UUID, prompt: String)] {
        let failedRowId = viewModel.pendingRetry?.errorItemId
        let checkpointsByAnchor: [UUID: (checkpointId: UUID, prompt: String)] = Dictionary(
            uniqueKeysWithValues: viewModel.chatRestorePointHeaders.compactMap { checkpoint in
                guard checkpoint.canRewind,
                      let anchorId = checkpoint.assistantTurnAnchorId else { return nil }
                return (
                    anchorId,
                    (
                        checkpointId: checkpoint.id,
                        prompt: checkpoint.userText ?? checkpoint.userLine
                    )
                )
            }
        )

        var result: [UUID: (checkpointId: UUID, prompt: String)] = [:]
        for row in rows {
            guard case .assistantTurn(let anchorId, let items) = row else { continue }
            guard anchorId != failedRowId, assistantTurnIsComplete(items) else { continue }
            if let checkpoint = checkpointsByAnchor[anchorId] {
                result[anchorId] = checkpoint
            }
        }
        return result
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

    private var consoleProjectName: String {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "No project" : (path as NSString).lastPathComponent
    }

    private var consoleSessionViews: [(session: LatticeConsoleSession, entries: [LatticeConsoleEntry])] {
        consoleStore.sessions.map { session in
            (session, session.lines.map(LatticeConsoleEntry.init(rawLine:)))
        }
    }

    private var filteredConsoleSessions: [(session: LatticeConsoleSession, entries: [LatticeConsoleEntry])] {
        let query = consoleSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return consoleSessionViews
        }
        return consoleSessionViews.compactMap { pair in
            let entries = pair.entries.filter {
                $0.raw.localizedCaseInsensitiveContains(query)
                    || $0.category.localizedCaseInsensitiveContains(query)
                    || $0.message.localizedCaseInsensitiveContains(query)
            }
            return entries.isEmpty ? nil : (pair.session, entries)
        }
    }

    private var filteredConsoleText: String {
        filteredConsoleSessions
            .flatMap { pair in
                ["# \(pair.session.title)"] + pair.entries.map(\.raw)
            }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var consoleDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build Console")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(consoleProjectName) · \(consoleStore.sessions.count) sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.9))
                    }
                }

                Spacer(minLength: 8)

                TextField("Filter log…", text: $consoleSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button {
                    copyTextAndToast(filteredConsoleText, toast: "Log copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Copy log")

                Button(role: .destructive) {
                    consoleStore.clear(projectPath: selectedProjectPath)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Clear log")

                Button {
                    showConsoleSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Close console")
            }

            Group {
                if filteredConsoleSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No console output yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Builds, local runs, and diagnostics for this project will show up here.")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(filteredConsoleSessions.enumerated()), id: \.element.session.id) { _, pair in
                                consoleSessionSection(pair.session, entries: pair.entries)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 3)
    }

    @ViewBuilder
    private func consoleSessionSection(_ session: LatticeConsoleSession, entries: [LatticeConsoleEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(session.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(session.startedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.82))
                Spacer(minLength: 0)
                Text("\(entries.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.74))
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    consoleEntryRow(entry)
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func consoleEntryRow(_ entry: LatticeConsoleEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.category.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.78))
                .tracking(0.35)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                )
                .frame(width: 82, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let timestamp = entry.timestamp {
                    Text(timestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.82))
                }
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.018))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }

    private var mainChatStack: some View {
        ZStack {
            LatticeWindowBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 10) {
                VStack(spacing: 10) {
                    contextBar
                        .padding(.top, 10)
                }
                .padding(.horizontal, 12)

                messageList
                    .padding(.top, 2)
                if hasSelectedProject, showConsoleSheet, !showProjectHub {
                    consoleDock
                        .padding(.horizontal, 12)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.985, anchor: .bottom)),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                        )
                }
                inputBar
            }
            // Inspector column resizes the chat strip every frame; implicit animations + nested Materials
            // re-sample blur and read as a flash. Pin layout without animating chrome for this value.
            .animation(nil, value: showProjectPanel)
        }
    }

    @ToolbarContentBuilder
    private var latticeMainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            if !selectedProjectPath.isEmpty, !showProjectHub {
                Button(action: runOnSimulatorDirect) {
                    Group {
                        if isDirectRunInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.primary)
                                .offset(x: 0.5)
                        }
                    }
                    .frame(width: 30, height: 30, alignment: .center)
                }
                .help(buildRunHelp)
                .disabled(!canLocalBuildAndRun)
                .controlSize(.small)

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
                    HStack(spacing: 6) {
                        Image(systemName: localRunDestination == .macOS ? "laptopcomputer" : (localRunDestination == .iOSDevice ? "iphone.gen3" : "iphone"))
                            .font(.caption2)
                        Text(runTargetLabel)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .controlSize(.small)
            }
        }
        if hasSelectedProject, !showProjectHub {
            ToolbarItem(placement: .automatic) {
                Button {
                    showConsoleSheet.toggle()
                } label: {
                    Image(systemName: showConsoleSheet ? "terminal.fill" : "terminal")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .help(showConsoleSheet ? "Hide Console" : "Show Console")
                .controlSize(.small)
            }
            // TODO(lattice-history-ui): Restore this toolbar entry after full regression pass.
        }
        if !showProjectHub {
            ToolbarItem(placement: .automatic) {
                Button { showProjectPanel.toggle() } label: {
                    Image(systemName: showProjectPanel ? "sidebar.trailing" : "sidebar.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .help(showProjectPanel ? "Hide Project" : "Show Project")
                .controlSize(.small)
            }
        }
        if !showProjectHub {
            ToolbarItem(placement: .automatic) {
                Button {
                    showProjectHub = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .help("Project Hub")
                .controlSize(.small)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                openWindow(id: "lattice-settings")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .help("Settings")
            .controlSize(.small)
        }
    }

    private var chatSurfaceWithSheets: some View {
        mainChatStack
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: directRunBanner != nil)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: showConsoleSheet)
            .preferredColorScheme(preferredAppearance)
            .tint(accentTint)
            .toolbar { latticeMainToolbar }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var layeredMainInterface: some View {
        chatSurfaceWithSheets
            .inspector(isPresented: $showProjectPanel) {
                ProjectInspectorView(
                    chatViewModel: viewModel,
                    selectedProjectPath: $selectedProjectPath,
                    developmentTeam: $latticeDevelopmentTeam,
                    bundleIdentifierOverride: $latticeBundleIdentifierOverride,
                    discoveredDevelopmentTeams: discoveredDevelopmentTeams,
                    showSigningHelpPopover: $showSigningHelpPopover,
                    onAskLatticeToFix: { message in
                        showProjectPanel = true
                        viewModel.send(message, apiKey: activeAPIKey, context: chatContext)
                    }
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .frame(minWidth: 720, minHeight: 520)
            .overlay {
                if showProjectHub {
                    ProjectHubView(
                        recentStore: recentStore,
                        selectedProjectPath: $selectedProjectPath,
                        showProjectHub: $showProjectHub,
                        onProjectCreated: { createdRoot, platform in
                            switch platform {
                            case .iOS:
                                latticeLocalRunDestinationRaw = LatticeLocalRunDestination.iOSSimulator.rawValue
                            case .macOS:
                                latticeLocalRunDestinationRaw = LatticeLocalRunDestination.macOS.rawValue
                            case .watchOS:
                                latticeLocalRunDestinationRaw = LatticeLocalRunDestination.watchOSSimulator.rawValue
                            }
                            selectedSimulatorID = ""
                            selectedProjectPath = createdRoot.path
                        },
                        onRemoveProject: { project in
                            forgetProjectConversation(for: project)
                        }
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.985)),
                                removal: .opacity
                            )
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
    }

    var body: some View {
        layeredMainInterface
        .sheet(item: $selectedImagePreview) { attachment in
            LatticeImagePreviewSheet(attachment: attachment)
        }
        .sheet(item: $composerEditingAttachment) { attachment in
            LatticeImageEditorSheet(attachment: attachment) { edited in
                replaceComposerAttachment(attachment, with: edited)
            }
        }
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
            loadBundleIdentifierOverrideForSelectedProject()
            refreshResolvedProjectBundleIdentifier()
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
            sidebarLayoutScrollToken &+= 1
            if !isOpen && selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showProjectHub = true
            }
        }
        .onChange(of: selectedProjectPath) { old, new in
            let canonical = ChatSessionPersistence.canonicalProjectPath(new)
            if !canonical.isEmpty, canonical != new {
                selectedProjectPath = canonical
                return
            }
            viewModel.syncProjectPath(new)
            consoleStore.setVisibleProject(path: new)
            directRunBanner = nil
            directRunBannerIsError = false
            let trimmed = ChatSessionPersistence.canonicalProjectPath(new)
            let oldTrimmed = ChatSessionPersistence.canonicalProjectPath(old)
            if trimmed.isEmpty {
                showProjectHub = true
                supportedRunDestinations = .allRunDestinations
                discoveredDevelopmentTeams = []
            } else if trimmed != oldTrimmed {
                recentStore.add(path: trimmed)
            }
            loadBundleIdentifierOverrideForSelectedProject()
            refreshResolvedProjectBundleIdentifier()
            refreshProjectDerivedSettings()
            applyGeneratedSummaryIconIfPossible()
        }
        .onChange(of: latticeBundleIdentifierOverride) { _, _ in
            persistBundleIdentifierOverrideForSelectedProject()
        }
        .onChange(of: selectedModelSupportsImages) { _, supportsImages in
            if !supportsImages {
                composerImageAttachments.removeAll()
            }
        }
        .onChange(of: viewModel.projectSummary) { _, _ in
            applyGeneratedSummaryIconIfPossible()
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
        DirectRunBannerCard(
            rawText: text,
            isError: directRunBannerIsError,
            destination: localRunDestination,
            destinationLabel: currentRunTargetLabel,
            onDismiss: {
                directRunBanner = nil
                directRunBannerIsError = false
            },
            onFix: {
                sendBuildErrorToChat(text)
            },
            onCopy: {
                copyTextAndToast(text, toast: directRunBannerIsError ? "Copied build error" : "Copied build details")
            },
            onShowFullLog: {
                consoleStore.append(text, category: "build", projectPath: selectedProjectPath)
                consoleSearch = ""
                showConsoleSheet = true
            },
            onOpenDestination: {
                openSelectedRunDestination()
            },
            canOpenDestination: localRunDestination == .iOSSimulator || localRunDestination == .watchOSSimulator
        )
        .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentRunTargetLabel: String {
        switch localRunDestination {
        case .macOS:
            return "My Mac"
        case .iOSDevice:
            return devicesForToolbar.first(where: { $0.id == selectedSimulatorID })?.name
                ?? simulatorStore.connectedDevices.first(where: { $0.id == selectedSimulatorID })?.name
                ?? "Connected device"
        case .iOSSimulator, .watchOSSimulator:
            return simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID })?.name ?? "Simulator"
        }
    }

    private func openSelectedRunDestination() {
        guard localRunDestination == .iOSSimulator || localRunDestination == .watchOSSimulator else { return }
        let args = selectedSimulatorID.isEmpty ? ["-a", "Simulator"] : ["-a", "Simulator", "--args", "-CurrentDeviceUDID", selectedSimulatorID]
        let config = Process()
        config.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        config.arguments = args
        try? config.run()
    }

    private func applyGeneratedSummaryIconIfPossible() {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let summary = viewModel.projectSummary, !summary.isEmpty else { return }
        Task { @MainActor in
            try? ProjectAppIconWriter.writeGenerated(summary: summary, projectRoot: URL(fileURLWithPath: path))
        }
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

        return HStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {
                Spacer(minLength: 0)

                contextProjectTitle(
                    folderShort: folderShort,
                    path: projectRoot,
                    providerLabel: prov.displayName,
                    modelLabel: modelLabel
                )

                workspaceDivider

                contextRunPill(icon: simIcon, title: "Run target", value: simLabel)

                if let summary = viewModel.projectSummary, !summary.isEmpty {
                    workspaceDivider
                    ProjectSummaryStrip(summary: summary, projectPath: selectedProjectPath, compact: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 1180)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.045),
                                Color.primary.opacity(0.018)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var workspaceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1, height: 34)
            .padding(.vertical, 2)
    }

    private func contextProjectTitle(folderShort: String, path: String, providerLabel: String, modelLabel: String) -> some View {
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(folderShort)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("Current project")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.70))
                        .tracking(0.35)

                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 3, height: 3)

                    Text(providerLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary.opacity(0.84))
                        .lineLimit(1)

                    Text(modelLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    .foregroundStyle(.secondary.opacity(0.72))
                    .tracking(0.4)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .leading)
        }
    }

    // MARK: - Message list

    private var transcriptEmptyPlaceholder: some View {
        VStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 72, height: 72)
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.95))
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 6) {
                Text("Start the next build pass")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Ask Lattice for a screen, a feature, a polish pass, or a fix. It will inspect the current project and keep building from there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 8) {
                emptyPromptChip("Build a screen")
                emptyPromptChip("Polish the UI")
                emptyPromptChip("Fix a build")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 42)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func emptyPromptChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.045))
            )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).id("transcriptTop")
                    VStack(alignment: .leading, spacing: 14) {
                        if viewModel.items.isEmpty {
                            transcriptEmptyPlaceholder
                        }
                        let rows = buildChatDisplayRows(from: viewModel.items)
                        let restoreActionsByRowId = assistantTurnRestoreActions(for: rows)
                        ForEach(rows) { row in
                            transcriptRowView(row, restoreActionsByRowId: restoreActionsByRowId)
                            .id(row.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("transcriptBottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color.clear)
            .overlay(alignment: .top) {
                if let banner = directRunBanner {
                    directRunBannerView(banner)
                        .padding(.top, 10)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.985, anchor: .top))
                        )
                }
            }
            .onChange(of: viewModel.transcriptScrollToBottomToken) { _, _ in
                scrollTranscriptToBottom(using: proxy)
            }
            .onChange(of: sidebarLayoutScrollToken) { _, _ in
                scrollTranscriptToBottom(using: proxy)
            }
            .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private func transcriptRowView(
        _ row: ChatDisplayRow,
        restoreActionsByRowId: [UUID: (checkpointId: UUID, prompt: String)]
    ) -> some View {
        switch row {
        case .user(let item):
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                ChatItemView(item: item, onOpenAttachment: { selectedImagePreview = $0 })
            }
            .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .working(let item):
            TransientWorkingRow(item: item, phase: viewModel.livePhase)
                .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .assistantTurn(let anchorId, let items):
            let restoreAction = restoreActionsByRowId[anchorId]
            AssistantTurnCard(
                items: items,
                livePhase: viewModel.livePhase,
                reduceMotion: reduceMotion,
                pendingRetry: viewModel.pendingRetry,
                canRestoreLastPass: restoreAction != nil,
                onRetry: {
                    viewModel.performRetry(apiKey: activeAPIKey, context: chatContext)
                },
                onRestoreLastPass: {
                    guard let restoreAction else { return }
                    viewModel.rewindCompletedTurn(checkpointId: restoreAction.checkpointId)
                    input = restoreAction.prompt
                    composerHeight = 42
                }
            )
            .frame(maxWidth: latticeTranscriptColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scrollTranscriptToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo("transcriptBottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !composerImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(composerImageAttachments) { attachment in
                            composerAttachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 2)
                    .animation(.spring(response: 0.26, dampingFraction: 0.84), value: composerImageAttachments.map(\.id))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .center, spacing: 0) {
                if selectedModelSupportsImages {
                    Button(action: chooseComposerImages) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.82))
                            .frame(width: 34, height: 34)
                            .background {
                                Circle()
                                    .fill(Color.primary.opacity(0.06))
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Attach image")
                    .padding(.leading, 6)
                }

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Describe the app or feature to build…")
                            .foregroundStyle(.secondary.opacity(0.96))
                            .padding(.leading, selectedModelSupportsImages ? 8 : 12)
                            .padding(.top, 11)
                            .allowsHitTesting(false)
                    }

                    LatticeComposerTextView(
                        text: $input,
                        measuredHeight: $composerHeight,
                        onSubmit: sendMessage,
                        onPasteImages: pasteImagesFromClipboardIfAvailable
                    )
                    .frame(height: min(max(composerHeight, 42), 160))
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    if hasComposerDraft {
                        sendMessage()
                    } else {
                        viewModel.stop()
                    }
                }) {
                    Group {
                        if viewModel.isRunning && !hasComposerDraft {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : Color.secondary)
                                .frame(width: 34, height: 34)
                                .background {
                                    Circle().fill(canSend ? Color.red.opacity(0.9) : Color.primary.opacity(0.12))
                                }
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : Color.secondary)
                                .frame(width: 34, height: 34)
                                .background {
                                    if canSend {
                                        Circle().fill(Color.accentColor.gradient)
                                    } else {
                                        Circle().fill(Color.primary.opacity(0.12))
                                    }
                                }
                                .shadow(color: canSend ? Color.accentColor.opacity(0.40) : .clear, radius: 8, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(viewModel.isRunning && !hasComposerDraft ? "Stop Build" : "Build With Lattice")
                .padding(.trailing, 6)
                .padding(.vertical, 2)
            }
            .latticeElevatedCard(radius: 18, strokeOpacity: isComposerDropTarget ? 0.18 : 0.08, shadowOpacity: 0.04)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(isComposerDropTarget ? 0.08 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isComposerDropTarget ? 0.55 : 0),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )
            )
            .onDrop(
                of: [
                    UTType.fileURL.identifier,
                    UTType.png.identifier,
                    UTType.jpeg.identifier,
                    UTType.tiff.identifier,
                    UTType.gif.identifier,
                    UTType.image.identifier
                ],
                isTargeted: selectedModelSupportsImages ? $isComposerDropTarget : .constant(false),
                perform: handleComposerDrop(providers:)
            )

            Text(composerTips[composerTipIndex % composerTips.count])
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.78))
                .padding(.leading, 4)
                .opacity(latticeShowComposerTips ? 1 : 0)
                .accessibilityHidden(!latticeShowComposerTips)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .opacity(canSend || viewModel.isRunning ? 1 : 0.78)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            composerTipIndex += 1
        }
    }

    private var hasInputText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasComposerDraft: Bool {
        hasInputText || !composerImageAttachments.isEmpty
    }

    private var canSend: Bool {
        guard !activeAPIKey.isEmpty else { return false }
        if viewModel.isRunning {
            return !hasComposerDraft
        }
        return hasComposerDraft
    }

    private func sendMessage() {
        guard !viewModel.isRunning else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerImageAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        input = ""
        composerImageAttachments.removeAll()
        viewModel.send(text, attachments: attachments, apiKey: activeAPIKey, context: chatContext)
    }

    private func chooseComposerImages() {
        let panel = NSOpenPanel()
        panel.title = "Attach images"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        let existingPaths = Set(composerImageAttachments.map(\.path))
        let picked = panel.urls.compactMap(LatticeImageAttachment.init(url:))
            .filter { !existingPaths.contains($0.path) }
        guard !picked.isEmpty else { return }
        composerImageAttachments.append(contentsOf: picked)
    }

    private func handleComposerDrop(providers: [NSItemProvider]) -> Bool {
        guard selectedModelSupportsImages else { return false }
        let canLoad = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard canLoad else { return false }

        for provider in providers {
            loadComposerAttachment(from: provider)
        }
        return true
    }

    private func loadComposerAttachment(from provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      let attachment = LatticeImageAttachment(url: url) else { return }
                DispatchQueue.main.async {
                    appendComposerAttachments([attachment])
                }
            }
            return
        }

        let imageTypeIdentifiers = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            UTType.gif.identifier,
            UTType.image.identifier
        ]
        guard let typeIdentifier = imageTypeIdentifiers.first(where: provider.hasItemConformingToTypeIdentifier(_:)) else {
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data else { return }
            let mimeType: String? = switch typeIdentifier {
            case UTType.png.identifier: "image/png"
            case UTType.jpeg.identifier: "image/jpeg"
            case UTType.gif.identifier: "image/gif"
            case UTType.tiff.identifier: "image/tiff"
            default: nil
            }
            guard let attachment = LatticeImageAttachment.fromImageData(data, mimeType: mimeType) else { return }
            DispatchQueue.main.async {
                appendComposerAttachments([attachment])
            }
        }
    }

    private func appendComposerAttachments(_ attachments: [LatticeImageAttachment]) {
        guard !attachments.isEmpty else { return }
        let existingPaths = Set(composerImageAttachments.map(\.path))
        let fresh = attachments.filter { !existingPaths.contains($0.path) }
        guard !fresh.isEmpty else { return }
        composerImageAttachments.append(contentsOf: fresh)
    }

    private func replaceComposerAttachment(_ old: LatticeImageAttachment, with new: LatticeImageAttachment) {
        guard let index = composerImageAttachments.firstIndex(where: { $0.id == old.id }) else { return }
        composerImageAttachments[index] = new
    }

    private func pasteImagesFromClipboardIfAvailable() -> Bool {
        guard selectedModelSupportsImages else { return false }

        var attachments: [LatticeImageAttachment] = []
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            attachments.append(contentsOf: urls.compactMap(LatticeImageAttachment.init(url:)))
        }

        if attachments.isEmpty, let pastedImage = NSImage(pasteboard: NSPasteboard.general),
           let attachment = LatticeImageAttachment.fromClipboardImage(pastedImage) {
            attachments.append(attachment)
        }

        guard !attachments.isEmpty else { return false }
        appendComposerAttachments(attachments)
        return true
    }

    @ViewBuilder
    private func composerAttachmentChip(_ attachment: LatticeImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                composerEditingAttachment = attachment
            } label: {
                LatticeAttachmentThumbnail(
                    attachment: attachment,
                    width: latticeComposerAttachmentWidth,
                    height: latticeComposerAttachmentHeight,
                    cornerRadius: 14,
                    showsFileName: false
                )
            }
            .buttonStyle(.plain)
            .onDrag {
                draggingComposerAttachmentID = attachment.id
                return NSItemProvider(object: attachment.id.uuidString as NSString)
            }
            .onDrop(
                of: [UTType.plainText.identifier],
                delegate: ComposerAttachmentReorderDropDelegate(
                    target: attachment,
                    attachments: $composerImageAttachments,
                    draggingID: $draggingComposerAttachmentID
                )
            )

            Button {
                composerImageAttachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .help("Remove image")
            .padding(6)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
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
        consoleStore.beginSession(
            title: localRunDestination == .macOS ? "Local run on My Mac" : "Local run on \(currentRunTargetLabel)",
            category: "xcodebuild",
            projectPath: root
        )

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
            bundleIdentifierOverride: effectiveBundleIdentifierForContext,
            developmentTeam: resolvedDevelopmentTeam,
            projectSummary: viewModel.projectSummary
        )
    }

    private var effectiveBundleIdentifierForContext: String? {
        let override = latticeBundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        let resolved = resolvedProjectBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return defaultBundleIdentifierForSelectedProject
    }

    private func forgetProjectConversation(for project: RecentProject) {
        let path = ChatSessionPersistence.canonicalProjectPath(project.path)
        guard !path.isEmpty else {
            recentStore.remove(project)
            return
        }

        let selectedPath = ChatSessionPersistence.canonicalProjectPath(selectedProjectPath)
        let isCurrentProject = path == selectedPath

        if isCurrentProject {
            viewModel.clear()
            consoleStore.clear(projectPath: path)
            latticeDevelopmentTeam = ""
            resolvedProjectBundleIdentifier = ""
            directRunBanner = nil
            directRunBannerIsError = false
            selectedSimulatorID = ""
            selectedProjectPath = ""
        } else {
            ChatSessionPersistence.clear(projectPath: path)
            LatticeChatRestoreHistory.clear(projectPath: path)
            consoleStore.clear(projectPath: path)
        }

        removeBundleIdentifierOverride(forProjectPath: path)
        recentStore.remove(project)
    }

    private var defaultBundleIdentifierForSelectedProject: String? {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !slug.isEmpty else { return nil }
        return "com.lattice.\(slug)"
    }

    private var bundleIdentifierOverrides: [String: String] {
        guard let data = latticeBundleIdentifierOverridesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func loadBundleIdentifierOverrideForSelectedProject() {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            latticeBundleIdentifierOverride = ""
            return
        }
        latticeBundleIdentifierOverride = bundleIdentifierOverrides[path] ?? ""
    }

    private func persistBundleIdentifierOverrideForSelectedProject() {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        var overrides = bundleIdentifierOverrides
        let trimmed = latticeBundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            overrides.removeValue(forKey: path)
        } else {
            overrides[path] = trimmed
        }
        if let data = try? JSONEncoder().encode(overrides),
           let string = String(data: data, encoding: .utf8) {
            latticeBundleIdentifierOverridesJSON = string
        }
    }

    private func removeBundleIdentifierOverride(forProjectPath rawPath: String) {
        let path = ChatSessionPersistence.canonicalProjectPath(rawPath)
        guard !path.isEmpty else { return }
        var overrides = bundleIdentifierOverrides
        guard overrides.removeValue(forKey: path) != nil else { return }
        if let data = try? JSONEncoder().encode(overrides),
           let string = String(data: data, encoding: .utf8) {
            latticeBundleIdentifierOverridesJSON = string
        }
    }

    private func refreshResolvedProjectBundleIdentifier() {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            resolvedProjectBundleIdentifier = ""
            return
        }
        Task {
            do {
                let resolved = try await ProjectAppIdentityEditor.resolvedBundleIdentifier(projectRoot: URL(fileURLWithPath: path))
                await MainActor.run {
                    resolvedProjectBundleIdentifier = resolved ?? ""
                }
            } catch {
                await MainActor.run {
                    resolvedProjectBundleIdentifier = ""
                }
            }
        }
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

private struct LatticeConsoleEntry: Identifiable {
    let id = UUID()
    let raw: String
    let timestamp: String?
    let category: String
    let message: String

    nonisolated init(rawLine: String) {
        self.raw = rawLine
        let pattern = #"^\[([^\]]+)\]\s+\[([^\]]+)\]\s*(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)),
           let timestampRange = Range(match.range(at: 1), in: rawLine),
           let categoryRange = Range(match.range(at: 2), in: rawLine),
           let messageRange = Range(match.range(at: 3), in: rawLine) {
            self.timestamp = String(rawLine[timestampRange])
            self.category = String(rawLine[categoryRange]).replacingOccurrences(of: "-", with: " ")
            let parsedMessage = String(rawLine[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            self.message = parsedMessage.isEmpty ? rawLine : parsedMessage
        } else {
            self.timestamp = nil
            self.category = "log"
            self.message = rawLine
        }
    }
}

private struct DirectRunBannerCard: View {
    let rawText: String
    let isError: Bool
    let destination: LatticeLocalRunDestination
    let destinationLabel: String
    let onDismiss: () -> Void
    let onFix: () -> Void
    let onCopy: () -> Void
    let onShowFullLog: () -> Void
    let onOpenDestination: () -> Void
    let canOpenDestination: Bool

    @State private var showDetails = false

    private enum StatusKind {
        case success
        case warning
        case error
    }

    private var lines: [String] {
        rawText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var headline: String {
        if statusKind == .error { return "Build failed" }
        if statusKind == .warning { return "Build completed with warnings" }
        if lines.first?.lowercased().hasPrefix("launched ") == true {
            return "Opened in \(destinationLabel)"
        }
        return "Build succeeded"
    }

    private var subtitle: String {
        if statusKind == .error {
            return "Review the error or send it back to Lattice."
        }
        if statusKind == .warning {
            return "The build completed, but Xcode reported warnings worth checking."
        }
        switch destination {
        case .iOSSimulator, .watchOSSimulator:
            return "The app built and launch was requested for the selected simulator."
        case .iOSDevice:
            return "The app built and launch was requested on the connected device."
        case .macOS:
            return "The app built and was opened on this Mac."
        }
    }

    private var statusKind: StatusKind {
        if isError { return .error }
        if visibleDetailLines.contains(where: { $0.localizedCaseInsensitiveContains("warning:") }) {
            return .warning
        }
        return .success
    }

    private var accentColor: Color {
        switch statusKind {
        case .success: return .green
        case .warning: return .yellow
        case .error: return .orange
        }
    }

    private var visibleDetailLines: [String] {
        lines.filter { line in
            let lower = line.lowercased()
            return lower != "** build succeeded **"
                && !lower.hasPrefix("/usr/bin/touch ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusKind == .error ? "exclamationmark.triangle.fill" : (statusKind == .warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor.opacity(0.92))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Local run")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .tracking(0.36)
                        Text(destinationLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary.opacity(0.84))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.045))
                            )
                    }
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.88))
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(Circle().fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            if let first = visibleDetailLines.first {
                Text(first)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.86))
                    .textSelection(.enabled)
            }

            if visibleDetailLines.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary.opacity(0.82))
                                .frame(width: 10)
                            Text(showDetails ? "Hide details" : "View details")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary.opacity(0.92))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        ScrollView([.vertical, .horizontal]) {
                            Text(visibleDetailLines.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 68, maxHeight: 180)
                    }
                }
            }

            HStack(spacing: 8) {
                if isError {
                    Button(action: onFix) {
                        Label("Let Lattice fix it", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if canOpenDestination {
                    Button(action: onOpenDestination) {
                        Label("Open Simulator", systemImage: "play.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .modifier(BuildBannerCopyButtonStyle())

                Button("Full log", action: onShowFullLog)
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    statusKind == .error
                        ? Color.orange.opacity(0.045)
                        : statusKind == .warning
                            ? Color.yellow.opacity(0.045)
                            : Color.green.opacity(0.04)
                )
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    accentColor.opacity(statusKind == .success ? 0.12 : 0.16),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.026), radius: 6, y: 2)
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

private struct AssistantVisibleContent {
    let prose: String
    let director: AssistantDirectorMetadata?
}

private func assistantVisibleContent(from raw: String) -> AssistantVisibleContent {
    let split = AssistantProjectFooterParser.splitDirectorFooter(fromAssistantText: raw)
    return AssistantVisibleContent(prose: split.body, director: split.metadata)
}

/// While tokens stream in, skip heavy markdown cleanup (regex over the full buffer every chunk).
private func assistantStreamDisplayText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "\r\n", with: "\n")
}

private func copyTextToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct MessageCopyButton: View {
    let text: String
    var trailing: Bool = false
    var expands: Bool = true
    @State private var copied = false

    var body: some View {
        Button {
            copyTextToPasteboard(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
        .frame(maxWidth: expands ? .infinity : nil, alignment: trailing ? .trailing : .leading)
    }
}

private struct AssistantSourcesButton: View {
    let count: Int
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "globe.badge.chevron.backward" : "globe")
                    .font(.caption.weight(.semibold))
                Text("Sources")
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.88))
            }
            .foregroundStyle(.secondary.opacity(0.94))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .help(count == 1 ? "Show source" : "Show sources")
    }
}

private struct AssistantSourcesDrawer: View {
    let sources: [AssistantWebSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(sources.count == 1 ? "1 source used" : "\(sources.count) sources used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.92))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(source.domain)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.78))
                                    .textCase(.uppercase)
                                if source.kind == .fetchedPage {
                                    Text("opened")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.accentColor.opacity(0.92))
                                        .textCase(.uppercase)
                                }
                            }

                            Text(source.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary.opacity(0.94))
                                .fixedSize(horizontal: false, vertical: true)

                            Text(source.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.86))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 10)

                        Button {
                            guard let url = URL(string: source.url) else { return }
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.026))
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ProjectSummaryStrip: View {
    let summary: LatticeProjectSummary
    let projectPath: String
    var compact: Bool = false

    private var appNameLine: String {
        let value = summary.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Untitled app" : value
    }

    private var conceptLine: String? {
        let value = summary.concept?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var detailPills: [(String, String)] {
        var rows: [(String, String)] = []
        if let navigation = summary.navigation?.trimmingCharacters(in: .whitespacesAndNewlines), !navigation.isEmpty {
            rows.append(("arrow.triangle.branch", navigation))
        }
        if let designDirection = summary.designDirection?.trimmingCharacters(in: .whitespacesAndNewlines), !designDirection.isEmpty {
            rows.append(("paintpalette", designDirection))
        }
        let openIssues = (summary.openIssues ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !openIssues.isEmpty {
            rows.append(("exclamationmark.bubble", openIssues.count == 1 ? "1 open issue" : "\(openIssues.count) open issues"))
        }
        return rows
    }

    var body: some View {
        Group {
            if compact {
                compactHeaderLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    expandedLayout
                    compactLayout
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.035),
                                    Color.primary.opacity(0.014)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }

    private var expandedLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            ProjectSummaryBadge(summary: summary, projectPath: projectPath)

            VStack(alignment: .leading, spacing: 2) {
                Text("Current app")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.68))
                    .tracking(0.38)
                Text(appNameLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let conceptLine {
                    Text(conceptLine)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.94))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                ForEach(Array(detailPills.prefix(2).enumerated()), id: \.offset) { _, pill in
                    ProjectSummaryDetailPill(icon: pill.0, text: pill.1)
                }
            }
        }
    }

    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            ProjectSummaryBadge(summary: summary, projectPath: projectPath)

            VStack(alignment: .leading, spacing: 2) {
                Text("Current app")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.68))
                    .tracking(0.36)
                Text(appNameLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let conceptLine {
                    Text(conceptLine)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.92))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var compactHeaderLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            ProjectSummaryBadge(summary: summary, projectPath: projectPath)

            VStack(alignment: .leading, spacing: 1) {
                Text("Current app")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.66))
                    .tracking(0.34)
                Text(appNameLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let conceptLine {
                    Text(conceptLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 248, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct ProjectSummaryDetailPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.9))
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.96))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct ProjectSummaryBadge: View {
    let summary: LatticeProjectSummary
    let projectPath: String

    private var badgeImage: NSImage? {
        ProjectAppIconWriter.generatedImage(
            summary: summary,
            projectName: (projectPath as NSString).lastPathComponent,
            size: 68
        )
    }

    var body: some View {
        Group {
            if let badgeImage {
                Image(nsImage: badgeImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

private struct DirectorPhaseChip: View {
    let phase: LatticeDirectorPhase

    var body: some View {
        Text(phase.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct LatticeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void
    let onPasteImages: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.string = text

        scrollView.documentView = textView

        DispatchQueue.main.async {
            context.coordinator.updateHeight(from: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateHeight(from: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var measuredHeight: CGFloat

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            _text = text
            _measuredHeight = measuredHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            let updated = textView.string
            if text != updated {
                text = updated
            }
            updateHeight(from: textView)
        }

        func updateHeight(from textView: ComposerNSTextView) {
            let next = textView.fittingHeight
            if abs(measuredHeight - next) > 0.5 {
                measuredHeight = next
            }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (() -> Bool)?

    var fittingHeight: CGFloat {
        guard let textContainer, let layoutManager else { return 42 }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(usedRect.height + (textContainerInset.height * 2))
        return max(42, contentHeight)
    }

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey && !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if onPasteImages?() == true {
            return
        }
        super.paste(sender)
    }
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
                Text(assistantStreamDisplayText(text))
                    .font(.body)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .multilineTextAlignment(multilineTextAlignment)
                    .lineSpacing(4)
            } else {
                Text(normalizeAssistantText(text))
                    .font(.body)
                    .textSelection(.disabled)
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

private func assistantTurnIsComplete(_ items: [ChatItem]) -> Bool {
    for item in items {
        switch item.kind {
        case .assistant(_, let streaming):
            if streaming { return false }
        case .reasoning(_, let streaming):
            if streaming { return false }
        case .tool(_, _, _, _, let running):
            if running { return false }
        default:
            break
        }
    }
    return true
}

private func nonEmptyTrimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// One-line subtitle for a tool row (paths → filenames, long bash → clipped).
private func latticeFriendlyToolSubtitle(name: String, input: String) -> String {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "" }
    if name == "web_search",
       let queryRange = t.range(of: #""query"\s*:\s*"([^"]+)""#, options: .regularExpression) {
        let query = String(t[queryRange]).replacingOccurrences(of: #""query"\s*:\s*""#, with: "", options: .regularExpression)
        return query.dropLast().description
    }
    if name == "fetch_webpage",
       let urlRange = t.range(of: #""url"\s*:\s*"([^"]+)""#, options: .regularExpression) {
        let url = String(t[urlRange]).replacingOccurrences(of: #""url"\s*:\s*""#, with: "", options: .regularExpression)
        return url.dropLast().description
    }
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

private struct AssistantWebSource: Identifiable, Hashable {
    enum Kind {
        case searchResult
        case fetchedPage
    }

    let id: String
    let kind: Kind
    let title: String
    let domain: String
    let url: String
    let note: String
}

private func assistantToolInputValue(_ input: String, key: String) -> String? {
    guard let data = input.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object[key] as? String else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func canonicalWebSourceID(for urlString: String) -> String {
    guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else {
        return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    components.scheme = "https"
    components.fragment = nil
    if let queryItems = components.queryItems, !queryItems.isEmpty {
        let filtered = queryItems.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && name != "ref" && name != "ref_src"
        }
        components.queryItems = filtered.isEmpty ? nil : filtered
    }
    return components.string ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseAssistantWebSearchSources(output: String, query: String?) -> [AssistantWebSource] {
    let lines = output.components(separatedBy: .newlines)
    var results: [AssistantWebSource] = []
    var currentTitle: String?
    var currentDomain: String?
    var currentURL: String?
    var currentSnippet: String?

    func flushCurrent() {
        guard let title = nonEmptyTrimmed(currentTitle),
              let domain = nonEmptyTrimmed(currentDomain),
              let url = nonEmptyTrimmed(currentURL) else {
            currentTitle = nil
            currentDomain = nil
            currentURL = nil
            currentSnippet = nil
            return
        }

        let note = nonEmptyTrimmed(currentSnippet)
            ?? query.map { "Relevant result for \"\($0)\"." }
            ?? "Relevant result from a web search."

        results.append(
            AssistantWebSource(
                id: canonicalWebSourceID(for: url),
                kind: .searchResult,
                title: title,
                domain: domain,
                url: url,
                note: note
            )
        )

        currentTitle = nil
        currentDomain = nil
        currentURL = nil
        currentSnippet = nil
    }

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            flushCurrent()
            currentTitle = String(line.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression))
        } else if line.hasPrefix("Domain: ") {
            currentDomain = String(line.dropFirst("Domain: ".count))
        } else if line.hasPrefix("URL: ") {
            currentURL = String(line.dropFirst("URL: ".count))
        } else if line.hasPrefix("Snippet: ") {
            currentSnippet = String(line.dropFirst("Snippet: ".count))
        } else if line.isEmpty {
            flushCurrent()
        }
    }

    flushCurrent()
    return results
}

private func parseAssistantFetchedWebSource(output: String, requestedURL: String?) -> AssistantWebSource? {
    let lines = output.components(separatedBy: .newlines)
    var fetchedURL = nonEmptyTrimmed(requestedURL)
    var title: String?
    var domain: String?
    var summary: String?

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("Fetched: ") {
            fetchedURL = String(line.dropFirst("Fetched: ".count))
        } else if line.hasPrefix("Domain: ") {
            domain = String(line.dropFirst("Domain: ".count))
        } else if line.hasPrefix("Title: ") {
            title = String(line.dropFirst("Title: ".count))
        } else if line.hasPrefix("Summary: ") {
            summary = String(line.dropFirst("Summary: ".count))
        }
    }

    guard let url = nonEmptyTrimmed(fetchedURL) else { return nil }
    let resolvedDomain = nonEmptyTrimmed(domain)
        ?? URLComponents(string: url)?.host?.lowercased()
        ?? url
    let resolvedTitle = nonEmptyTrimmed(title) ?? resolvedDomain
    let note = nonEmptyTrimmed(summary) ?? "Lattice opened this page to read the source directly."

    return AssistantWebSource(
        id: canonicalWebSourceID(for: url),
        kind: .fetchedPage,
        title: resolvedTitle,
        domain: resolvedDomain,
        url: url,
        note: note
    )
}

private func assistantWebSources(from items: [ChatItem]) -> [AssistantWebSource] {
    var fetchedSources: [AssistantWebSource] = []
    var fetchedIDs = Set<String>()
    var searchSources: [AssistantWebSource] = []
    var searchIDs = Set<String>()

    for item in items {
        guard case .tool(let name, let input, let output, let isError, let isRunning) = item.kind,
              !isError,
              !isRunning,
              let output = nonEmptyTrimmed(output) else {
            continue
        }

        switch name {
        case "fetch_webpage":
            let requestedURL = assistantToolInputValue(input, key: "url")
            if let source = parseAssistantFetchedWebSource(output: output, requestedURL: requestedURL),
               fetchedIDs.insert(source.id).inserted {
                fetchedSources.append(source)
            }
        case "web_search":
            let query = assistantToolInputValue(input, key: "query")
            for source in parseAssistantWebSearchSources(output: output, query: query) {
                guard searchIDs.insert(source.id).inserted else { continue }
                searchSources.append(source)
            }
        default:
            break
        }
    }

    if !fetchedSources.isEmpty {
        return fetchedSources
    }
    return Array(searchSources.prefix(4))
}

/// Assistant markdown: its own light surface so long replies are not one giant slab with tools.
private struct AssistantProseCard: View {
    let text: String
    let streaming: Bool
    /// When nested inside `AssistantTurnCard`, outer chrome is handled by the turn container.
    var unifiedTurn: Bool = false

    private var isErrorText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("error:")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isErrorText {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Something went wrong")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange.opacity(0.96))
                        Text("The provider rejected this request.")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.86))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
            }
            MarkdownBlock(text: text, isStreaming: streaming)
        }
        .padding(.horizontal, unifiedTurn ? 2 : 16)
        .padding(.vertical, unifiedTurn ? 6 : 14)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .background(proseBackground)
        .overlay(proseStroke)
    }

    @ViewBuilder
    private var proseBackground: some View {
        if unifiedTurn {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var proseStroke: some View {
        if isErrorText {
            RoundedRectangle(cornerRadius: unifiedTurn ? 12 : LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: unifiedTurn ? 12 : LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                        .fill(Color.orange.opacity(0.04))
                )
        } else if !unifiedTurn {
            RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        } else {
            EmptyView()
        }
    }
}

private struct TransientWorkingRow: View {
    let item: ChatItem
    var phase: LatticeDirectorPhase?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            if let phase {
                DirectorPhaseChip(phase: phase)
            }
            Text(phase == .idea ? "Shaping the request" : "Working in the background")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .id(item.id)
    }
}

private struct ReasoningCollapsibleCard: View {
    let text: String
    let streaming: Bool
    var reduceMotion: Bool = false
    var unifiedTurn: Bool = false
    @State private var expanded = false

    private var previewSnippet: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let firstLine = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? t
        let cleaned = streaming ? assistantStreamDisplayText(firstLine) : normalizeAssistantText(firstLine)
        if cleaned.count > 72 { return String(cleaned.prefix(69)) + "…" }
        return cleaned
    }

    private var fullReasoningText: String {
        streaming ? assistantStreamDisplayText(text) : normalizeAssistantText(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(streaming ? "Live notes" : "Work notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            if streaming {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        if text.isEmpty, streaming {
                            Text("…")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.98))
                        } else if !previewSnippet.isEmpty {
                            Text(previewSnippet)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary.opacity(0.98))
                                .lineLimit(streaming ? 2 : 1)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Spacer(minLength: 4)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary.opacity(0.96))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(unifiedTurn ? Color.primary.opacity(0.028) : Color.secondary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if text.isEmpty, streaming {
                    Text("…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.92))
                        .padding(.leading, 4)
                } else {
                    Text(fullReasoningText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.86))
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(4)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, unifiedTurn ? 0 : 4)
        .padding(.vertical, unifiedTurn ? 4 : 6)
        .frame(maxWidth: latticeAssistantProseMaxWidth, alignment: .leading)
        .onChange(of: streaming) { _, isStreaming in
            if !isStreaming {
                if reduceMotion {
                    expanded = false
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        expanded = false
                    }
                }
            }
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
                    .padding(.vertical, 5)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.018))
                    )
            } else {
                content()
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DirectorOutcomeBlock: View {
    let metadata: AssistantDirectorMetadata

    private var rows: [(String, String)] {
        var result: [(String, String)] = []
        if let built = metadata.built?.trimmingCharacters(in: .whitespacesAndNewlines), !built.isEmpty {
            result.append(("Built", built))
        }
        if let changed = metadata.changed?.trimmingCharacters(in: .whitespacesAndNewlines), !changed.isEmpty {
            result.append(("Changed", changed))
        }
        if let needsInput = metadata.needsUserInput?.trimmingCharacters(in: .whitespacesAndNewlines),
           !needsInput.isEmpty,
           needsInput.lowercased() != "none" {
            result.append(("Needs your input", needsInput))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.82))
                        .tracking(0.4)
                    Text(row.1)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.022))
        )
    }
}

private struct AssistantWorkingIndicatorRow: View {
    let phase: LatticeDirectorPhase?

    private var title: String {
        switch phase {
        case .idea: return "Understanding the request"
        case .plan: return "Planning the build"
        case .build: return "Editing files and building"
        case .verify: return "Verifying the result"
        case .polish: return "Polishing the app"
        case nil: return "Still working"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary.opacity(0.94))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
    }
}

/// One assistant “turn”: prose, reasoning, and tools in one column.
private struct AssistantTurnCard: View {
    let items: [ChatItem]
    var livePhase: LatticeDirectorPhase?
    var reduceMotion: Bool = false
    var pendingRetry: PendingRetryState?
    var canRestoreLastPass: Bool = false
    var onRetry: () -> Void
    var onRestoreLastPass: () -> Void

    @State private var workCollapsed = true
    @State private var sourcesExpanded = false

    private var pieces: [AssistantTurnPiece] {
        assistantTurnPieces(from: items)
    }

    private var isTurnComplete: Bool {
        for item in items {
            switch item.kind {
            case .assistant(_, let streaming):
                if streaming { return false }
            case .reasoning(_, let streaming):
                if streaming { return false }
            case .tool(_, _, _, _, let running):
                if running { return false }
            default:
                break
            }
        }
        return true
    }

    private var hasWorkDetails: Bool {
        pieces.contains {
            switch $0 {
            case .reasoning(let item):
                if case .reasoning(let text, _) = item.kind {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            case .tools(let run):
                return !run.isEmpty
            case .assistant:
                return false
            }
        }
    }

    private var reasoningPieceCount: Int {
        pieces.reduce(into: 0) { count, piece in
            if case .reasoning(let item) = piece,
               case .reasoning(let text, _) = item.kind,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
    }

    private var toolStepCount: Int {
        pieces.reduce(into: 0) { count, piece in
            if case .tools(let run) = piece { count += run.count }
        }
    }

    private var collapsedWorkSummary: String {
        let reasoningCount = reasoningPieceCount
        let toolCount = toolStepCount
        if !isTurnComplete {
            switch (reasoningCount > 0, toolCount > 0) {
            case (true, true):
                return toolCount == 1 ? "View build log · 1 tool" : "View build log · \(toolCount) tools"
            case (true, false):
                return "View build log"
            case (false, true):
                return toolCount == 1 ? "View build log · 1 tool" : "View build log · \(toolCount) tools"
            default:
                return "View activity"
            }
        }
        switch (reasoningCount > 0, toolCount > 0) {
        case (true, true):
            return toolCount == 1 ? "View build log · 1 tool" : "View build log · \(toolCount) tools"
        case (true, false):
            return "View notes"
        case (false, true):
            return toolCount == 1 ? "View build log · 1 tool" : "View build log · \(toolCount) tools"
        default:
            return "View activity"
        }
    }

    private var latestAssistantText: String? {
        for item in items.reversed() {
            if case .assistant(let text, _) = item.kind {
                let prose = assistantVisibleContent(from: text).prose.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { return text }
            }
        }
        return nil
    }

    private var primaryAssistantText: String {
        guard let latestAssistantText else { return "" }
        return assistantVisibleContent(from: latestAssistantText).prose
    }

    private var latestDirectorMetadata: AssistantDirectorMetadata? {
        guard let latestAssistantText else { return nil }
        return assistantVisibleContent(from: latestAssistantText).director
    }

    private var hasOutcomeFooter: Bool {
        guard let metadata = latestDirectorMetadata else { return false }
        return metadata.built?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || metadata.changed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || metadata.needsUserInput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var webSources: [AssistantWebSource] {
        assistantWebSources(from: items)
    }

    private var showsRetry: Bool {
        guard let pendingRetry else { return false }
        return items.contains { $0.id == pendingRetry.errorItemId }
    }

    private var retryButtonTitle: String {
        pendingRetry?.resumeFromLastStableStep == true ? "Resume this response" : "Retry this response"
    }

    private var copyableText: String {
        if isTurnComplete {
            var blocks: [String] = []
            let primary = normalizeAssistantText(primaryAssistantText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !primary.isEmpty {
                blocks.append(primary)
            }
            if let metadata = latestDirectorMetadata {
                if let built = metadata.built?.trimmingCharacters(in: .whitespacesAndNewlines), !built.isEmpty {
                    blocks.append("Built: \(built)")
                }
                if let changed = metadata.changed?.trimmingCharacters(in: .whitespacesAndNewlines), !changed.isEmpty {
                    blocks.append("Changed: \(changed)")
                }
                if let needsInput = metadata.needsUserInput?.trimmingCharacters(in: .whitespacesAndNewlines), !needsInput.isEmpty {
                    blocks.append("Needs your input: \(needsInput)")
                }
            }
            return blocks.joined(separator: "\n\n")
        }
        var blocks = items.compactMap { item -> String? in
            guard case .assistant(let text, _) = item.kind else { return nil }
            let cleaned = normalizeAssistantText(assistantVisibleContent(from: text).prose).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        if let metadata = latestDirectorMetadata {
            if let built = metadata.built?.trimmingCharacters(in: .whitespacesAndNewlines), !built.isEmpty {
                blocks.append("Built: \(built)")
            }
            if let changed = metadata.changed?.trimmingCharacters(in: .whitespacesAndNewlines), !changed.isEmpty {
                blocks.append("Changed: \(changed)")
            }
            if let needsInput = metadata.needsUserInput?.trimmingCharacters(in: .whitespacesAndNewlines), !needsInput.isEmpty {
                blocks.append("Needs your input: \(needsInput)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow

                VStack(alignment: .leading, spacing: 0) {
                    if workCollapsed {
                        if !primaryAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            AssistantProseCard(text: primaryAssistantText, streaming: !isTurnComplete, unifiedTurn: true)
                        }
                        if !isTurnComplete,
                           primaryAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            AssistantWorkingIndicatorRow(phase: livePhase)
                        }
                    } else {
                        ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
                            turnPiece(piece)
                            if index < pieces.count - 1 {
                                Divider()
                                    .opacity(0.22)
                                    .padding(.vertical, 5)
                            }
                        }
                    }

                    if isTurnComplete, hasOutcomeFooter, let metadata = latestDirectorMetadata {
                        DirectorOutcomeBlock(metadata: metadata)
                            .padding(.top, primaryAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 10)
                    }
                    if showsRetry {
                        Button(action: onRetry) {
                            Label(retryButtonTitle, systemImage: "arrow.clockwise.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 8)
                    }
                    if canRestoreLastPass, isTurnComplete {
                        Button(action: onRestoreLastPass) {
                            Label("Rewind this pass", systemImage: "arrow.uturn.backward.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, showsRetry ? 6 : 8)
                    }
                    if hasWorkDetails {
                        workDisclosureRow
                            .padding(.top, (isTurnComplete && hasOutcomeFooter) || showsRetry ? 10 : 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.032), radius: 10, y: 4)
            .fixedSize(horizontal: false, vertical: true)

            if !copyableText.isEmpty || !webSources.isEmpty {
                HStack(spacing: 8) {
                    if !copyableText.isEmpty {
                        MessageCopyButton(text: copyableText, expands: false)
                    }
                    if !webSources.isEmpty {
                        AssistantSourcesButton(count: webSources.count, expanded: sourcesExpanded) {
                            if reduceMotion {
                                sourcesExpanded.toggle()
                            } else {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    sourcesExpanded.toggle()
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if sourcesExpanded, !webSources.isEmpty {
                    AssistantSourcesDrawer(sources: webSources)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .onAppear {
            workCollapsed = true
            if webSources.isEmpty {
                sourcesExpanded = false
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if isTurnComplete {
                Text("Lattice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            } else if let livePhase {
                DirectorPhaseChip(phase: livePhase)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
    }

    private var workDisclosureRow: some View {
        Button {
            if reduceMotion {
                workCollapsed.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.16)) {
                    workCollapsed.toggle()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.84))
                    .frame(width: 10, alignment: .center)

                Text(workCollapsed ? collapsedWorkSummary : "Hide build log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.94))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                AssistantProseCard(text: assistantVisibleContent(from: text).prose, streaming: streaming, unifiedTurn: true)
            }
        case .tools(let toolItems):
            LatticeToolActivitySection(unifiedTurn: true) {
                ToolActivityTimelineView(tools: toolItems, reduceMotion: reduceMotion)
            }
        }
    }
}

/// Vertical tool run with status dots and connectors between steps.
private struct ToolActivityTimelineView: View {
    let tools: [ChatItem]
    var reduceMotion: Bool = false
    @State private var expandedOutputStepId: UUID?
    @State private var expandedGroupId: UUID?

    private enum DisplayRow: Identifiable {
        case step(ChatItem)
        case grouped(id: UUID, name: String, items: [ChatItem])

        var id: UUID {
            switch self {
            case .step(let item):
                return item.id
            case .grouped(let id, _, _):
                return id
            }
        }
    }

    private var expandAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.9)
    }

    private var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        var index = 0

        while index < tools.count {
            guard case .tool(let name, _, _, _, _) = tools[index].kind else {
                rows.append(.step(tools[index]))
                index += 1
                continue
            }

            if name == "read_file" || name == "write_file" {
                var group = [tools[index]]
                var nextIndex = index + 1
                while nextIndex < tools.count {
                    guard case .tool(let nextName, _, _, _, _) = tools[nextIndex].kind, nextName == name else {
                        break
                    }
                    group.append(tools[nextIndex])
                    nextIndex += 1
                }

                if group.count >= 2 {
                    rows.append(.grouped(id: group[0].id, name: name, items: group))
                    index = nextIndex
                    continue
                }
            }

            rows.append(.step(tools[index]))
            index += 1
        }

        return rows
    }

    var body: some View {
        let timeline = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                switch row {
                case .step(let t):
                    if case .tool(let name, let input, let output, let isError, let isRunning) = t.kind {
                        ToolTimelineStepRow(
                            isFirst: index == 0,
                            isLast: index == displayRows.count - 1,
                            stableId: t.id,
                            name: name,
                            input: input,
                            output: output,
                            isError: isError,
                            isRunning: isRunning,
                            reduceMotion: reduceMotion,
                            outputExpanded: expandedOutputStepId == t.id,
                            onToggleOutput: {
                                if reduceMotion {
                                    expandedOutputStepId = expandedOutputStepId == t.id ? nil : t.id
                                } else {
                                    withAnimation(expandAnimation) {
                                        expandedOutputStepId = expandedOutputStepId == t.id ? nil : t.id
                                    }
                                }
                            }
                        )
                    }
                case .grouped(let id, let name, let items):
                    ToolTimelineGroupRow(
                        isFirst: index == 0,
                        isLast: index == displayRows.count - 1,
                        stableId: id,
                        name: name,
                        items: items,
                        reduceMotion: reduceMotion,
                        isExpanded: expandedGroupId == id,
                        expandedOutputStepId: expandedOutputStepId,
                        onToggleGroup: {
                            if reduceMotion {
                                expandedGroupId = expandedGroupId == id ? nil : id
                            } else {
                                withAnimation(expandAnimation) {
                                    expandedGroupId = expandedGroupId == id ? nil : id
                                }
                            }
                        },
                        onToggleOutput: { stepId in
                            if reduceMotion {
                                expandedOutputStepId = expandedOutputStepId == stepId ? nil : stepId
                            } else {
                                withAnimation(expandAnimation) {
                                    expandedOutputStepId = expandedOutputStepId == stepId ? nil : stepId
                                }
                            }
                        }
                    )
                }
            }
        }

        Group {
            if displayRows.count > 6 {
                ScrollView {
                    timeline
                }
                .frame(maxHeight: 280)
            } else {
                timeline
            }
        }
    }
}

private struct ToolTimelineGroupRow: View {
    let isFirst: Bool
    let isLast: Bool
    let stableId: UUID
    let name: String
    let items: [ChatItem]
    var reduceMotion: Bool = false
    let isExpanded: Bool
    let expandedOutputStepId: UUID?
    let onToggleGroup: () -> Void
    let onToggleOutput: (UUID) -> Void

    private var title: String {
        switch name {
        case "read_file":
            return items.count == 2 ? "Read 2 files" : "Read \(items.count) files"
        case "write_file":
            return items.count == 2 ? "Updated 2 files" : "Updated \(items.count) files"
        default:
            return "\(items.count) steps"
        }
    }

    private var subtitle: String {
        let names = items.compactMap { item -> String? in
            guard case .tool(_, let input, _, _, _) = item.kind else { return nil }
            let summary = latticeFriendlyToolSubtitle(name: name, input: input)
            return summary.isEmpty ? nil : summary
        }
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        if unique.count <= 3 {
            return unique.joined(separator: ", ")
        }
        let head = unique.prefix(3).joined(separator: ", ")
        return "\(head) +\(unique.count - 3) more"
    }

    private var containsRunningStep: Bool {
        items.contains {
            if case .tool(_, _, _, _, let isRunning) = $0.kind { return isRunning }
            return false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 2, height: 8)
                }
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 16, height: 16)
                    Image(systemName: name == "read_file" ? "doc.text" : "square.and.pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.9))
                }
                .frame(width: 18, height: 16)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 2)
                        .frame(minHeight: 18)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggleGroup) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary.opacity(0.88))
                            .frame(width: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary.opacity(0.94))
                                if containsRunningStep {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.82))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                        .opacity(0.3)
                        .padding(.leading, 8)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if case .tool(let itemName, let input, let output, let isError, let isRunning) = item.kind {
                                ToolTimelineStepRow(
                                    isFirst: index == 0,
                                    isLast: index == items.count - 1,
                                    stableId: item.id,
                                    name: itemName,
                                    input: input,
                                    output: output,
                                    isError: isError,
                                    isRunning: isRunning,
                                    reduceMotion: reduceMotion,
                                    outputExpanded: expandedOutputStepId == item.id,
                                    onToggleOutput: {
                                        onToggleOutput(item.id)
                                    }
                                )
                                .padding(.leading, 12)
                            }
                        }
                    }
                    .padding(.bottom, 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                }
            }
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 1)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 2)
        .id(stableId)
    }
}

private struct ToolTimelineStepRow: View {
    let isFirst: Bool
    let isLast: Bool
    let stableId: UUID
    let name: String
    let input: String
    let output: String?
    let isError: Bool
    let isRunning: Bool
    var reduceMotion: Bool = false
    let outputExpanded: Bool
    let onToggleOutput: () -> Void

    private var displayInput: String {
        latticeFriendlyToolSubtitle(name: name, input: input)
    }

    private var rowExpandAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.9)
    }

    private var toolIcon: String {
        switch name {
        case "bash": return "terminal"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "web_search": return "magnifyingglass"
        case "fetch_webpage": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var timelineDot: some View {
        ZStack {
            if isRunning {
                Circle()
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 2)
                    .frame(width: 14, height: 14)
                Circle()
                    .fill(Color.accentColor.opacity(0.95))
                    .frame(width: 7, height: 7)
            } else if isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.green.opacity(0.88))
            }
        }
        .frame(width: 18, height: 16)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 2, height: 8)
                }
                timelineDot
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 2)
                        .frame(minHeight: 18)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard let out = output, !out.isEmpty, !isRunning else { return }
                    onToggleOutput()
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: toolIcon)
                            .font(.caption2)
                            .foregroundStyle(isError ? Color.orange.opacity(0.95) : Color.secondary.opacity(0.92))
                            .frame(width: 14, alignment: .center)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary.opacity(0.94))
                                .lineLimit(1)
                            if !displayInput.isEmpty {
                                Text(displayInput)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.82))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                        } else if output != nil, !(output?.isEmpty ?? true) {
                            Image(systemName: outputExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning || (output?.isEmpty ?? true))

                if outputExpanded, let out = output, !out.isEmpty {
                    Group {
                        Divider()
                            .opacity(0.35)
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView {
                                Text(out)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(isError ? Color.orange : .primary)
                                    .textSelection(.disabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 8)
                                    .padding(.vertical, 6)
                            }
                            .frame(maxHeight: 120, alignment: .top)
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
                    .padding(.bottom, 4)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                }
            }
            .animation(rowExpandAnimation, value: outputExpanded)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(isError ? 0.09 : 0.05))
                    .frame(height: 1)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 2)
        .id(stableId)
    }
}

// MARK: - Chat item views

struct ChatItemView: View {
    let item: ChatItem
    var onOpenAttachment: ((LatticeImageAttachment) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(
                text: text,
                attachments: attachments,
                reduceMotion: reduceMotion,
                onOpenAttachment: onOpenAttachment
            )
        case .reasoning(let text, let isStreaming):
            ReasoningCollapsibleCard(text: text, streaming: isStreaming, reduceMotion: reduceMotion)
        case .working:
            TransientWorkingRow(item: item)
        case .assistant(let text, let isStreaming):
            AssistantBubble(text: text, isStreaming: isStreaming, reduceMotion: reduceMotion)
        case .tool(let name, let input, let output, let isError, let isRunning):
            ToolCard(name: name, input: input, output: output, isError: isError, isRunning: isRunning)
        }
    }
}

private struct LatticeAttachmentThumbnail: View {
    let attachment: LatticeImageAttachment
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 12
    var showsFileName: Bool = true

    private var image: NSImage? {
        NSImage(contentsOfFile: attachment.path)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.12),
                        Color.primary.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.52)],
                startPoint: .center,
                endPoint: .bottom
            )

            if showsFileName {
                Text(attachment.fileName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct LatticeAttachmentGrid: View {
    let attachments: [LatticeImageAttachment]
    var compact: Bool = false
    var onOpen: ((LatticeImageAttachment) -> Void)? = nil

    private var tileWidth: CGFloat {
        compact ? latticeComposerAttachmentWidth : latticeAttachmentTileWidth
    }

    private var tileHeight: CGFloat {
        compact ? latticeComposerAttachmentHeight : latticeAttachmentTileHeight
    }

    private var singleWidth: CGFloat {
        compact ? latticeComposerAttachmentWidth : latticeSingleMessageAttachmentWidth
    }

    private var singleHeight: CGFloat {
        compact ? latticeComposerAttachmentHeight : latticeSingleMessageAttachmentHeight
    }

    private var columns: [GridItem] {
        [
            GridItem(.fixed(tileWidth), spacing: 8),
            GridItem(.fixed(tileWidth), spacing: 8)
        ]
    }

    var body: some View {
        Group {
            if attachments.count == 1, let attachment = attachments.first {
                Button {
                    onOpen?(attachment)
                } label: {
                    LatticeAttachmentThumbnail(
                        attachment: attachment,
                        width: singleWidth,
                        height: singleHeight,
                        cornerRadius: compact ? 10 : 14,
                        showsFileName: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button {
                            onOpen?(attachment)
                        } label: {
                            LatticeAttachmentThumbnail(
                                attachment: attachment,
                                width: tileWidth,
                                height: tileHeight,
                                cornerRadius: compact ? 10 : 12,
                                showsFileName: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpen == nil)
                    }
                }
            }
        }
        .frame(maxWidth: attachments.count == 1 ? singleWidth : (tileWidth * 2) + 8, alignment: .leading)
    }
}

private struct ComposerAttachmentReorderDropDelegate: DropDelegate {
    let target: LatticeImageAttachment
    @Binding var attachments: [LatticeImageAttachment]
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != target.id,
              let from = attachments.firstIndex(where: { $0.id == draggingID }),
              let to = attachments.firstIndex(where: { $0.id == target.id }) else { return }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            let moved = attachments.remove(at: from)
            attachments.insert(moved, at: from < to ? to : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if !info.hasItemsConforming(to: [UTType.plainText.identifier]) {
            draggingID = nil
        }
    }
}

private enum LatticeImageEditorMode: String, CaseIterable, Identifiable {
    case draw
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draw: "Draw"
        case .crop: "Crop"
        }
    }
}

private func latticeFittedImageRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
        return .zero
    }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
        x: (container.width - fittedSize.width) / 2,
        y: (container.height - fittedSize.height) / 2,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

private func latticeNormalizedPoint(from location: CGPoint, in rect: CGRect) -> CGPoint? {
    guard rect.contains(location), rect.width > 0, rect.height > 0 else { return nil }
    return CGPoint(
        x: (location.x - rect.minX) / rect.width,
        y: 1 - ((location.y - rect.minY) / rect.height)
    )
}

private func latticeDisplayPoint(from normalized: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(
        x: rect.minX + (normalized.x * rect.width),
        y: rect.minY + ((1 - normalized.y) * rect.height)
    )
}

private struct LatticeImageEditorSheet: View {
    let attachment: LatticeImageAttachment
    let onSave: (LatticeImageAttachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: LatticeImageEditorMode = .draw
    @State private var strokes: [[CGPoint]] = []
    @State private var activeStroke: [CGPoint] = []
    @State private var cropRect: CGRect?
    @State private var cropStart: CGPoint?

    private var image: NSImage? {
        NSImage(contentsOfFile: attachment.path)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit image")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.96))
                        Text(attachment.fileName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Picker("Mode", selection: $mode) {
                        ForEach(LatticeImageEditorMode.allCases) { editorMode in
                            Text(editorMode.title).tag(editorMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    Button("Reset") {
                        strokes.removeAll()
                        activeStroke.removeAll()
                        cropRect = nil
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Save") {
                        saveEdits()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(image == nil)
                }

                if let image {
                    GeometryReader { proxy in
                        let fittedRect = latticeFittedImageRect(imageSize: image.latticePixelSize, in: proxy.size)
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white.opacity(0.04))

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: fittedRect.width, height: fittedRect.height)
                                .position(x: fittedRect.midX, y: fittedRect.midY)

                            cropOverlay(in: fittedRect)

                            if mode == .draw {
                                strokesOverlay(in: fittedRect, active: false)
                                strokesOverlay(in: fittedRect, active: true)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .gesture(editorGesture(in: fittedRect))
                    }
                    .frame(minWidth: 760, minHeight: 500)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 760, height: 500)
                        .overlay {
                            Label("Image unavailable", systemImage: "photo")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.86))
                        }
                }

                Text(mode == .crop ? "Drag to set the crop area." : "Draw directly over the image to mark up what matters.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 660)
    }

    private func editorGesture(in fittedRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch mode {
                case .draw:
                    guard let point = latticeNormalizedPoint(from: value.location, in: fittedRect) else { return }
                    if activeStroke.isEmpty {
                        activeStroke = [point]
                    } else {
                        activeStroke.append(point)
                    }
                case .crop:
                    guard let point = latticeNormalizedPoint(from: value.location, in: fittedRect) else { return }
                    if cropStart == nil {
                        cropStart = point
                    }
                    if let start = cropStart {
                        cropRect = CGRect(
                            x: min(start.x, point.x),
                            y: min(start.y, point.y),
                            width: abs(point.x - start.x),
                            height: abs(point.y - start.y)
                        ).standardized
                    }
                }
            }
            .onEnded { _ in
                switch mode {
                case .draw:
                    if activeStroke.count >= 2 {
                        strokes.append(activeStroke)
                    }
                    activeStroke.removeAll()
                case .crop:
                    cropStart = nil
                    if let cropRect, cropRect.width < 0.05 || cropRect.height < 0.05 {
                        self.cropRect = nil
                    }
                }
            }
    }

    @ViewBuilder
    private func cropOverlay(in fittedRect: CGRect) -> some View {
        if mode == .crop, let cropRect {
            let displayCrop = CGRect(
                x: fittedRect.minX + cropRect.minX * fittedRect.width,
                y: fittedRect.minY + (1 - cropRect.maxY) * fittedRect.height,
                width: cropRect.width * fittedRect.width,
                height: cropRect.height * fittedRect.height
            )

            Path { path in
                path.addRect(fittedRect)
                path.addRect(displayCrop)
            }
            .fill(Color.black.opacity(0.34), style: FillStyle(eoFill: true))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.94), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .frame(width: displayCrop.width, height: displayCrop.height)
                .position(x: displayCrop.midX, y: displayCrop.midY)
        }
    }

    @ViewBuilder
    private func strokesOverlay(in fittedRect: CGRect, active: Bool) -> some View {
        let source = active ? [activeStroke] : strokes
        ForEach(Array(source.enumerated()), id: \.offset) { _, stroke in
            Path { path in
                guard stroke.count >= 2 else { return }
                for (index, point) in stroke.enumerated() {
                    let mapped = latticeDisplayPoint(from: point, in: fittedRect)
                    if index == 0 {
                        path.move(to: mapped)
                    } else {
                        path.addLine(to: mapped)
                    }
                }
            }
            .stroke(
                active ? Color.orange : Color(nsColor: .systemPink),
                style: StrokeStyle(lineWidth: active ? 4 : 5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func saveEdits() {
        guard var image else { return }

        let normalizedCrop = cropRect?.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if let normalizedCrop,
           normalizedCrop.width > 0.05, normalizedCrop.height > 0.05,
           let cropped = image.latticeCropped(to: normalizedCrop) {
            image = cropped
        }

        let allStrokes = strokes + (activeStroke.count >= 2 ? [activeStroke] : [])
        let transformedStrokes: [[CGPoint]]
        if let normalizedCrop, normalizedCrop.width > 0.05, normalizedCrop.height > 0.05 {
            transformedStrokes = allStrokes.compactMap { stroke in
                let remapped = stroke.compactMap { point -> CGPoint? in
                    guard normalizedCrop.contains(point) else { return nil }
                    return CGPoint(
                        x: (point.x - normalizedCrop.minX) / normalizedCrop.width,
                        y: (point.y - normalizedCrop.minY) / normalizedCrop.height
                    )
                }
                return remapped.count >= 2 ? remapped : nil
            }
        } else {
            transformedStrokes = allStrokes
        }

        if !transformedStrokes.isEmpty, let annotated = image.latticeAnnotated(with: transformedStrokes) {
            image = annotated
        }

        guard let editedAttachment = LatticeImageAttachment.fromEditedImage(image, originalName: attachment.fileName) else { return }
        onSave(editedAttachment)
        dismiss()
    }
}

private struct LatticeImagePreviewSheet: View {
    let attachment: LatticeImageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    private var image: NSImage? {
        NSImage(contentsOfFile: attachment.path)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer(minLength: 0)

                if let image {
                    GeometryReader { proxy in
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.03))

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .scaleEffect(zoom)
                                .offset(offset)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .onTapGesture(count: 2) {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                        zoom = 1
                                        steadyZoom = 1
                                        offset = .zero
                                        steadyOffset = .zero
                                    }
                                }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.34), radius: 28, y: 18)
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    zoom = min(max(1, steadyZoom * value), 6)
                                }
                                .onEnded { _ in
                                    steadyZoom = zoom
                                    if zoom <= 1.01 {
                                        zoom = 1
                                        steadyZoom = 1
                                        offset = .zero
                                        steadyOffset = .zero
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard zoom > 1.01 else { return }
                                    offset = CGSize(
                                        width: steadyOffset.width + value.translation.width,
                                        height: steadyOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    steadyOffset = offset
                                }
                        )
                    }
                    .frame(maxWidth: 980, maxHeight: 760)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 420, height: 280)
                        .overlay {
                            Label("Preview unavailable", systemImage: "photo")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.86))
                        }
                }

                VStack(spacing: 4) {
                    Text(attachment.fileName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text("Pinch to zoom, drag to pan, double-click to reset, Escape to close")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

/// Sizes user `Text` to its natural width when short; only grows up to `maxContentWidth` when wrapping is needed.
/// (Plain `.frame(maxWidth:)` on `Text` still often adopts the cap width under a wide layout proposal from `LazyVStack`.)
private struct ShrinkWrappedBubbleTextLayout: Layout {
    var maxContentWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        let cap = min(proposal.width ?? .infinity, maxContentWidth)
        let natural = sub.sizeThatFits(.unspecified)
        if natural.width <= cap {
            return natural
        }
        let wrapped = sub.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
        return CGSize(width: min(wrapped.width, cap), height: wrapped.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sub = subviews.first else { return }
        sub.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct UserBubble: View {
    let text: String
    let attachments: [LatticeImageAttachment]
    var reduceMotion: Bool = false
    var onOpenAttachment: ((LatticeImageAttachment) -> Void)? = nil

    private var innerTextMaxWidth: CGFloat {
        max(44, latticeUserBubbleMaxWidth - 28)
    }

    private var copyableText: String {
        guard !attachments.isEmpty else { return text }
        let names = attachments.map(\.fileName).joined(separator: ", ")
        let attachmentLine = attachments.count == 1
            ? "Attached image: \(names)"
            : "Attached images: \(names)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attachmentLine }
        return "\(trimmed)\n\n\(attachmentLine)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: attachments.isEmpty ? 0 : 10) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    ShrinkWrappedBubbleTextLayout(maxContentWidth: innerTextMaxWidth) {
                        Text(trimmed)
                            .font(.body)
                            .textSelection(.disabled)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(4)
                            .foregroundStyle(.primary)
                    }
                }

                if !attachments.isEmpty {
                    LatticeAttachmentGrid(attachments: attachments, compact: false, onOpen: onOpenAttachment)
                }
            }
            .padding(.horizontal, attachments.isEmpty ? 14 : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 8 : 10))
            .padding(.vertical, attachments.isEmpty ? 10 : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 8 : 10))
            .background(
                RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                    .fill(Color.accentColor.opacity(0.20))
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.45),
                                Color.primary.opacity(0.12)
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.accentColor.opacity(0.08), radius: 10, y: 3)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)

            MessageCopyButton(text: copyableText, trailing: true)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool
    var reduceMotion: Bool = false
    @State private var streamPulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isStreaming && !reduceMotion)

            VStack(alignment: .leading, spacing: 5) {
                MarkdownBlock(text: text, isStreaming: isStreaming)
                if isStreaming, !text.isEmpty {
                    HStack(spacing: 5) {
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LatticeSurfaceTokens.cornerTranscript, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.12),
                                Color.accentColor.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.07), radius: 12, y: 3)

            Spacer(minLength: 12)
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
                        .textSelection(.disabled)
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
        case "web_search":     return "magnifyingglass"
        case "fetch_webpage":  return "globe"
        default:               return "wrench"
        }
    }
}

// MARK: - Supporting views

/// macOS 26+ Liquid Glass for inspector chrome; earlier OS uses bordered.
private struct LatticeChromeButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct ProjectInspectorView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var selectedProjectPath: String
    @Binding var developmentTeam: String
    @Binding var bundleIdentifierOverride: String
    let discoveredDevelopmentTeams: [String]
    @Binding var showSigningHelpPopover: Bool
    let onAskLatticeToFix: (String) -> Void

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

    @State private var pendingAppIcon: NSImage?
    @State private var appIconStatus: String?
    @State private var appIconBusy = false

    @State private var resolvedBundleIdentifier = ""
    @State private var bundleIdentifierLoading = false
    @State private var assistantHintNotice: String?

    private var projectIconSquircleSize: CGFloat { 52 }

    var body: some View {
        Form {
            Section {
                if !selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        Image(nsImage: sidebarAppMarkImage())
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: projectIconSquircleSize, height: projectIconSquircleSize)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: projectIconSquircleSize * 0.2237,
                                    style: .continuous
                                )
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: projectIconSquircleSize * 0.2237,
                                    style: .continuous
                                )
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 8) {
                            if bundleIdentifierLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Resolving bundle ID…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !resolvedBundleIdentifier.isEmpty {
                                Text("Bundle ID (from Xcode)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                Text(resolvedBundleIdentifier)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("Bundle ID not available until Xcode can read this project (see errors below if any).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            HStack(spacing: 8) {
                                Button("Choose app icon…") { pickInspectorAppIcon() }
                                    .modifier(LatticeChromeButtonModifier())
                                    .controlSize(.small)
                                if pendingAppIcon != nil {
                                    Button("Clear icon") {
                                        pendingAppIcon = nil
                                        appIconStatus = nil
                                    }
                                    .modifier(LatticeChromeButtonModifier())
                                    .controlSize(.small)
                                    Button {
                                        Task { await applyInspectorAppIcon() }
                                    } label: {
                                        if appIconBusy {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text("Apply icon")
                                        }
                                    }
                                    .modifier(LatticeChromeButtonModifier())
                                    .controlSize(.small)
                                    .disabled(appIconBusy)
                                }
                            }
                            if let appIconStatus {
                                Text(appIconStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let assistantHintNotice {
                                Text(assistantHintNotice)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }

                HStack(alignment: .center, spacing: 10) {
                    Button("Choose Folder") { chooseProjectFolder() }
                        .modifier(LatticeChromeButtonModifier())
                    Spacer(minLength: 8)
                    Button {
                        Task { await openProjectInXcode() }
                    } label: {
                        Group {
                            if openingXcode {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Open in Xcode", systemImage: "arrow.up.forward.app.fill")
                            }
                        }
                        .frame(minWidth: openingXcode ? 24 : nil)
                    }
                    .modifier(LatticeChromeButtonModifier())
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
                Text("⌘R builds and runs this project. Pick the simulator or device in the toolbar.")
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
                .modifier(LatticeChromeButtonModifier())
                .disabled(
                    identityApplyBusy
                        || selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                if let identityError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(identityError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Button("Ask AI to fix") {
                            let body = """
                            Project inspector error (please diagnose and fix the Xcode project or tell me exactly what to change in Xcode):

                            \(identityError)
                            """
                            onAskLatticeToFix(body)
                        }
                        .modifier(LatticeChromeButtonModifier())
                        .controlSize(.small)
                    }
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
                TextField("Bundle ID", text: $bundleIdentifierOverride)
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
        .onAppear {
            loadAppIdentity()
            refreshResolvedBundleIdentifier()
        }
        .onChange(of: selectedProjectPath) { _, _ in
            pendingAppIcon = nil
            appIconStatus = nil
            resolvedBundleIdentifier = ""
            assistantHintNotice = nil
            loadAppIdentity()
            refreshResolvedBundleIdentifier()
        }
        .onChange(of: chatViewModel.pendingInspectorHints) { _, hints in
            guard let hints else { return }
            mergeAssistantInspectorHints(hints)
            chatViewModel.clearPendingInspectorHints()
        }
    }

    private func mergeAssistantInspectorHints(_ hints: AssistantInspectorHints) {
        if let t = hints.developmentTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            developmentTeam = t
        }
        if let b = hints.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            bundleIdentifierOverride = b
        }
        if let p = hints.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            identityProductName = p
        }
        if let d = hints.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            identityDisplayName = d
        }
        if let v = hints.marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            identityMarketingVersion = v
        }
        if let n = hints.buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            identityBuildNumber = n
        }
        assistantHintNotice =
            "Values were filled from the latest assistant reply. Use “Apply to Xcode project” once the .xcodeproj is readable."
    }

    private var projectRootURL: URL? {
        let p = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : URL(fileURLWithPath: p)
    }

    private func sidebarAppMarkImage() -> NSImage {
        if let pendingAppIcon { return pendingAppIcon }
        let p = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else {
            return NSImage(named: NSImage.folderName) ?? NSImage()
        }
        let url = URL(fileURLWithPath: p)
        if let catalog = ProjectFolderIcon.firstProjectAppIcon(in: url) {
            return catalog
        }
        return ProjectFolderIcon.nsImage(forProjectFolder: p)
    }

    private func refreshResolvedBundleIdentifier() {
        guard let root = projectRootURL else {
            resolvedBundleIdentifier = ""
            bundleIdentifierLoading = false
            return
        }
        bundleIdentifierLoading = true
        Task {
            do {
                let id = try await ProjectAppIdentityEditor.resolvedBundleIdentifier(projectRoot: root)
                await MainActor.run {
                    resolvedBundleIdentifier = id ?? ""
                    bundleIdentifierLoading = false
                }
            } catch {
                await MainActor.run {
                    resolvedBundleIdentifier = ""
                    bundleIdentifierLoading = false
                }
            }
        }
    }

    private func pickInspectorAppIcon() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.image]
        panel.message = "Choose a PNG or JPEG for the app icon."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let img = NSImage(contentsOf: url) {
            pendingAppIcon = img
            appIconStatus = nil
        }
    }

    private func applyInspectorAppIcon() async {
        let path = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let image = pendingAppIcon else { return }
        appIconBusy = true
        appIconStatus = nil
        defer { appIconBusy = false }
        do {
            try ProjectAppIconWriter.write(image: image, projectRoot: URL(fileURLWithPath: path))
            pendingAppIcon = nil
            appIconStatus = "Icon updated. Reopen the project in Xcode if it was open."
        } catch {
            appIconStatus = error.localizedDescription
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
            try await ProjectAppIdentityEditor.save(
                projectRoot: URL(fileURLWithPath: path),
                identity: identity,
                bundleIdentifier: effectiveInspectorBundleIdentifier,
                developmentTeam: developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            loadAppIdentity()
            refreshResolvedBundleIdentifier()
        } catch {
            identityError = error.localizedDescription
        }
    }

    private var effectiveInspectorBundleIdentifier: String? {
        let override = bundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        let resolved = resolvedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        let name = (selectedProjectPath as NSString).lastPathComponent
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !slug.isEmpty else { return nil }
        return "com.lattice.\(slug)"
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



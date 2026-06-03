import Foundation

enum LatticeDirectorPhase: String, Codable, CaseIterable {
    case idea
    case plan
    case build
    case verify
    case polish

    var title: String {
        switch self {
        case .idea: return "Idea"
        case .plan: return "Plan"
        case .build: return "Build"
        case .verify: return "Verify"
        case .polish: return "Polish"
        }
    }

    static func parse(_ raw: String) -> LatticeDirectorPhase? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "idea": return .idea
        case "plan": return .plan
        case "build": return .build
        case "verify": return .verify
        case "polish": return .polish
        default: return nil
        }
    }
}

struct LatticeProjectSummary: Codable, Equatable {
    var appName: String?
    var concept: String?
    var surfaces: [String]

    init(appName: String? = nil, concept: String? = nil, surfaces: [String] = []) {
        self.appName = appName
        self.concept = concept
        self.surfaces = surfaces
    }

    var isEmpty: Bool {
        let hasAppName = !(appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasConcept = !(concept?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSurfaces = !surfaces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.isEmpty
        return !hasAppName && !hasConcept && !hasSurfaces
    }

    var surfacesLine: String {
        surfaces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " + ")
    }

    func merged(with other: LatticeProjectSummary) -> LatticeProjectSummary {
        let mergedSurfaces = other.surfaces.isEmpty ? surfaces : other.surfaces
        return LatticeProjectSummary(
            appName: other.appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? other.appName : appName,
            concept: other.concept?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? other.concept : concept,
            surfaces: mergedSurfaces
        )
    }
}

struct AssistantDirectorMetadata: Equatable {
    var built: String?
    var changed: String?
    var needsUserInput: String?
    var phase: LatticeDirectorPhase?
    var appName: String?
    var appConcept: String?
    var appSurfaces: [String] = []

    var isEmpty: Bool {
        [built, changed, needsUserInput, appName, appConcept]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .isEmpty && appSurfaces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.isEmpty && phase == nil
    }

    var projectSummary: LatticeProjectSummary? {
        let summary = LatticeProjectSummary(appName: appName, concept: appConcept, surfaces: appSurfaces)
        return summary.isEmpty ? nil : summary
    }
}

/// Values Lattice often prints at the end of an assistant reply (Bundle / Team / target metadata).
struct AssistantInspectorHints: Equatable {
    var bundleIdentifier: String?
    var developmentTeam: String?
    var productName: String?
    var displayName: String?
    var marketingVersion: String?
    var buildNumber: String?

    var isEmpty: Bool {
        [bundleIdentifier, developmentTeam, productName, displayName, marketingVersion, buildNumber]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .isEmpty
    }
}

enum AssistantProjectFooterParser {
    private static let directorMarker = "director summary:"

    static func splitDirectorFooter(fromAssistantText text: String) -> (body: String, metadata: AssistantDirectorMetadata?) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == directorMarker
        }) else {
            return (normalized.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let body = lines[..<markerIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let footerLines = Array(lines[(markerIndex + 1)...])
        let metadata = parseDirectorMetadataLines(footerLines)
        return (body, metadata?.isEmpty == false ? metadata : nil)
    }

    static func parseDirectorMetadata(fromAssistantText text: String) -> AssistantDirectorMetadata? {
        splitDirectorFooter(fromAssistantText: text).metadata
    }

    /// Best-effort parse of common “footer” lines from assistant markdown.
    static func parse(fromAssistantMarkdown text: String) -> AssistantInspectorHints? {
        var hints = AssistantInspectorHints()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for raw in lines {
            let line = normalizeMarkdownLine(raw)
            if line.isEmpty { continue }

            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?(?:bundle(?:\s+id)?|product_bundle_identifier)\s*[:：]\s*`?([^`\s]+)`?"#) {
                hints.bundleIdentifier = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?team(?:\s+id)?\s*[:：]\s*`?([^`\s]+)`?"#) {
                hints.developmentTeam = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?(?:project\s+name|product_name)\s*[:：]\s*(.+)$"#) {
                hints.productName = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?display\s+name\s*[:：]\s*(.+)$"#) {
                hints.displayName = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?(?:marketing\s+version|cfbundleshortversionstring|version)\s*[:：]\s*(.+)$"#) {
                hints.marketingVersion = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^(?:[-*•]\s*)?(?:\d+[.)]\s*)?(?:build|cfbundleversion|current_project_version)\s*[:：]\s*(.+)$"#) {
                hints.buildNumber = stripTrailingPunctuation(v)
            }
        }

        return hints.isEmpty ? nil : hints
    }

    private static func parseDirectorMetadataLines(_ lines: [String]) -> AssistantDirectorMetadata? {
        var metadata = AssistantDirectorMetadata()

        for raw in lines {
            let line = normalizeMarkdownLine(raw)
            if line.isEmpty { continue }

            if let v = match(line, pattern: #"(?i)^built\s*[:：]\s*(.+)$"#) {
                metadata.built = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^changed\s*[:：]\s*(.+)$"#) {
                metadata.changed = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^needs(?:\s+your)?\s+input\s*[:：]\s*(.+)$"#) {
                metadata.needsUserInput = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^phase\s*[:：]\s*(.+)$"#) {
                metadata.phase = LatticeDirectorPhase.parse(stripTrailingPunctuation(v))
            }
            if let v = match(line, pattern: #"(?i)^app\s+name\s*[:：]\s*(.+)$"#) {
                metadata.appName = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^app\s+concept\s*[:：]\s*(.+)$"#) {
                metadata.appConcept = stripTrailingPunctuation(v)
            }
            if let v = match(line, pattern: #"(?i)^app\s+surfaces\s*[:：]\s*(.+)$"#) {
                metadata.appSurfaces = splitSurfaces(v)
            }
        }

        return metadata.isEmpty ? nil : metadata
    }

    private static func normalizeMarkdownLine(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "*# "))
        return s
    }

    private static func match(_ line: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: line)
        else { return nil }
        return String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTrailingPunctuation(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".,;)]}\"'".contains(last) {
            t.removeLast()
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitSurfaces(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",|/")
        return raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

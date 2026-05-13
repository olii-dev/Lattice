import Foundation

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
}

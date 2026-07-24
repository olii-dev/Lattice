import Foundation

/// Shared helpers for mutating the textual contents of a `project.pbxproj` file.
///
/// Used by `ProjectAppIdentityEditor` and (eventually) `CapabilityApplicator` so there is a
/// single canonical implementation for locating app-target build configurations and
/// setting build settings inside an `XCBuildConfiguration` block.
enum PbxprojEditor {
    /// PBXNativeTarget application → XCConfigurationList → XCBuildConfiguration ids.
    static func applicationTargetConfigurationIDs(in pbx: String) -> [String]? {
        guard let appRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            return nil
        }
        let head = pbx[..<appRange.lowerBound]
        guard let listRange = head.range(of: "buildConfigurationList = ", options: .backwards) else {
            return nil
        }
        let tail = head[listRange.upperBound...]
        guard let space = tail.firstIndex(of: " ") else { return nil }
        let id = String(tail[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 24, id.range(of: "^[0-9A-Fa-f]{24}$", options: .regularExpression) != nil else {
            return nil
        }

        guard let listStart = pbx.range(of: "\t\t\(id) /*") else { return nil }
        guard let openBrace = pbx[listStart.upperBound...].range(of: "{") else { return nil }
        let scanStart = openBrace.upperBound
        guard let buildConfigsRange = pbx[scanStart...].range(of: "buildConfigurations = (") else { return nil }
        let afterParen = pbx[buildConfigsRange.upperBound...]
        guard let closeParen = afterParen.range(of: ");") else { return nil }
        let inner = String(afterParen[..<closeParen.lowerBound])
        let ids = hexIDs(in: inner)
        let unique = Array(Set(ids)).sorted()
        return unique.isEmpty ? nil : unique
    }

    /// Returns the range covering the full `{ ... }` block (including the leading id comment) for
    /// the given `XCBuildConfiguration` id.
    static func blockRange(forConfigurationID id: String, in pbx: String) -> Range<String.Index>? {
        let anchor = "\t\t\(id) /*"
        guard let start = pbx.range(of: anchor) else { return nil }
        guard let brace = pbx[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = brace
        let endIndex = pbx.endIndex
        while i < endIndex {
            let ch = pbx[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return start.lowerBound..<pbx.index(after: i)
                }
            }
            i = pbx.index(after: i)
        }
        return nil
    }

    /// Sets `key` to `value` inside an `XCBuildConfiguration` block.
    /// Replaces an existing `\t\t\t\tkey = ...;` line if present, otherwise inserts a new one
    /// immediately after `buildSettings = {`.
    static func setOrInsertBuildSetting(_ block: String, key: String, value: String) -> String {
        let linePattern = "\\t\\t\\t\\t\(NSRegularExpression.escapedPattern(for: key)) = [^\\n]*;"
        if let regex = try? NSRegularExpression(pattern: linePattern, options: []) {
            let ns = block as NSString
            let full = NSRange(location: 0, length: ns.length)
            let replacement = "\t\t\t\t\(key) = \(value);"
            let replaced = regex.stringByReplacingMatches(in: block, options: [], range: full, withTemplate: replacement)
            if replaced != block {
                return replaced
            }
        }
        guard let insertAt = block.range(of: "buildSettings = {") else { return block }
        let insertion = "\n\t\t\t\t\(key) = \(value);"
        var out = block
        out.insert(contentsOf: insertion, at: insertAt.upperBound)
        return out
    }

    /// Extracts all 24-char (uppercase or lowercase) hex IDs from `text`, in order of appearance.
    static func hexIDs(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{24}") else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }

    /// Escapes a string for use as the value of a pbxproj build setting.
    static func pbxEscape(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\"") else {
            return "\"" + trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        if trimmed.contains(" ") || trimmed.contains("$") || trimmed.isEmpty {
            return "\"" + trimmed + "\""
        }
        return trimmed
    }

    /// Strips surrounding double-quotes from a pbxproj build-setting value and unescapes `\"`.
    static func stripQuotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            t.removeFirst()
            t.removeLast()
            return t.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return t
    }
}

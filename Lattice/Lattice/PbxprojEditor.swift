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

    // MARK: - Entitlements wiring

    /// Result of wiring an `.entitlements` file reference into a `project.pbxproj`.
    struct EntitlementsWiringResult {
        /// The (possibly modified) pbxproj text.
        let modifiedPbx: String
        /// `true` when wiring was performed; `false` when the entitlements setting was already present.
        let wasModified: Bool
        /// The 24-char hex `PBXFileReference` id created for the entitlements file, if any.
        let fileReferenceID: String?
        /// The 24-char hex `PBXBuildFile` id created for the entitlements file, if any.
        let buildFileID: String?
    }

    /// Thrown when entitlements wiring cannot locate the expected pbxproj structures.
    enum EntitlementsWiringError: Error, CustomStringConvertible {
        case noApplicationTarget
        case noResourcesBuildPhase
        case noSourceGroup
        case noEndFileReferenceSection
        case noEndBuildFileSection
        case resourcesPhaseFilesNotFound
        case groupChildrenNotFound

        var description: String {
            switch self {
            case .noApplicationTarget: return "Could not locate application target in pbxproj."
            case .noResourcesBuildPhase: return "Could not locate the app target's Resources build phase."
            case .noSourceGroup: return "Could not locate the app target's source group."
            case .noEndFileReferenceSection: return "Could not find end of PBXFileReference section."
            case .noEndBuildFileSection: return "Could not find end of PBXBuildFile section."
            case .resourcesPhaseFilesNotFound: return "Could not locate the `files = (` list inside the app target's Resources build phase."
            case .groupChildrenNotFound: return "Could not locate the `children = (` list inside the app target's source group."
            }
        }
    }

    /// Idempotently wires an `.entitlements` file into a `project.pbxproj`.
    ///
    /// `relativePath` is like `"LatticeTplApp/LatticeTplApp.entitlements"`. The base file name
    /// (last path component) is the entitlements file name, e.g. `"LatticeTplApp.entitlements"`.
    ///
    /// If `CODE_SIGN_ENTITLEMENTS = "<path>";` is already present, returns `wasModified: false`
    /// and leaves the pbxproj unchanged. Otherwise:
    /// - adds a `PBXFileReference` (entitlements type)
    /// - adds a `PBXBuildFile` referencing it
    /// - adds the build file to the app target's Resources build phase
    /// - adds the file reference to the app target's source group
    /// - sets `CODE_SIGN_ENTITLEMENTS` on every app-target config block
    static func ensureEntitlementsFileReference(
        in pbx: String,
        relativePath: String
    ) throws -> EntitlementsWiringResult {
        let escapedPath = pbxEscape(relativePath)
        // 1. Idempotency: the exact setting we would write is already present.
        if pbx.contains("CODE_SIGN_ENTITLEMENTS = \(escapedPath);") {
            return EntitlementsWiringResult(
                modifiedPbx: pbx,
                wasModified: false,
                fileReferenceID: nil,
                buildFileID: nil
            )
        }

        let baseName = (relativePath as NSString).lastPathComponent
        let existingIDs = Set(hexIDs(in: pbx))
        let fileRefID = generateUniqueHexID(avoiding: existingIDs)
        let buildFileID = generateUniqueHexID(avoiding: existingIDs.union([fileRefID]))

        var out = pbx

        // 3. PBXFileReference (entitlements).
        let fileRefLine = "\t\t\(fileRefID) /* \(baseName) */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = \(baseName); sourceTree = \"<group>\"; };\n"
        guard let endFileRefRange = out.range(of: "/* End PBXFileReference section */") else {
            throw EntitlementsWiringError.noEndFileReferenceSection
        }
        out.insert(contentsOf: fileRefLine, at: endFileRefRange.lowerBound)

        // 4. PBXBuildFile.
        let buildFileLine = "\t\t\(buildFileID) /* \(baseName) in Resources */ = {isa = PBXBuildFile; fileRef = \(fileRefID) /* \(baseName) */; };\n"
        guard let endBuildFileRange = out.range(of: "/* End PBXBuildFile section */") else {
            throw EntitlementsWiringError.noEndBuildFileSection
        }
        out.insert(contentsOf: buildFileLine, at: endBuildFileRange.lowerBound)

        // 5. Add to app target's Resources build phase `files = (...)`.
        let resourcesPhaseID = try findResourcesBuildPhaseID(in: out)
        out = try addToBuildPhaseFiles(
            resourcesPhaseID,
            buildFileID: buildFileID,
            comment: "\(baseName) in Resources",
            in: out
        )

        // 6. Add file reference to app target's source group `children = (...)`.
        let sourceGroupID = try findSourceGroupID(in: out)
        out = try addToGroupChildren(
            sourceGroupID,
            fileRefID: fileRefID,
            comment: baseName,
            in: out
        )

        // 7. Set CODE_SIGN_ENTITLEMENTS on every app-target config block.
        guard let configIDs = applicationTargetConfigurationIDs(in: out) else {
            throw EntitlementsWiringError.noApplicationTarget
        }
        for id in configIDs {
            guard let range = blockRange(forConfigurationID: id, in: out) else {
                throw EntitlementsWiringError.noApplicationTarget
            }
            let block = String(out[range])
            let updated = setOrInsertBuildSetting(block, key: "CODE_SIGN_ENTITLEMENTS", value: escapedPath)
            out.replaceSubrange(range, with: updated)
        }

        return EntitlementsWiringResult(
            modifiedPbx: out,
            wasModified: true,
            fileReferenceID: fileRefID,
            buildFileID: buildFileID
        )
    }

    /// Generates a random 24-char uppercase-hex id that does not collide with any id in `avoiding`.
    static func generateUniqueHexID(avoiding set: Set<String>) -> String {
        let charset: [Character] = Array("0123456789ABCDEF")
        while true {
            var id = ""
            id.reserveCapacity(24)
            for _ in 0..<24 {
                id.append(charset.randomElement()!)
            }
            if !set.contains(id) {
                return id
            }
        }
    }

    /// Finds the Resources build phase id of the **application** target.
    ///
    /// Strategy: find `productType = "com.apple.product-type.application";`, then walk forward to
    /// the target's `buildPhases = ( ... )` list and return the id whose comment is `/* Resources */`.
    static func findResourcesBuildPhaseID(in pbx: String) throws -> String {
        guard let productTypeRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            throw EntitlementsWiringError.noApplicationTarget
        }
        // The `buildPhases = (` for this target comes after `productType` declaration is unusual;
        // in the template buildPhases precedes productType. So scan the enclosing target block by
        // walking back to the target's opening `{`, then forward from there.
        let head = pbx[..<productTypeRange.lowerBound]
        // The target block opens with `\t\t<ID> /* <Name> */ = {`. Find the most recent `= {`
        // before productType — that is the target block opener.
        guard let blockOpenRange = head.range(of: "= {", options: .backwards) else {
            throw EntitlementsWiringError.noApplicationTarget
        }
        let region = pbx[blockOpenRange.upperBound..<productTypeRange.upperBound]
        guard let phasesRange = region.range(of: "buildPhases = (") else {
            throw EntitlementsWiringError.noResourcesBuildPhase
        }
        let afterParen = region[phasesRange.upperBound...]
        guard let closeParen = afterParen.range(of: ")") else {
            throw EntitlementsWiringError.noResourcesBuildPhase
        }
        let inner = String(afterParen[..<closeParen.lowerBound])
        // Each entry looks like `\t\t\t\t<ID> /* Resources */,`. Find the one with `Resources` comment.
        for line in inner.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("/* Resources */") else { continue }
            if let id = hexIDs(in: String(line)).first {
                return id
            }
        }
        throw EntitlementsWiringError.noResourcesBuildPhase
    }

    /// Finds the `PBXGroup` that contains the app's source `.swift` files.
    ///
    /// Strategy: scan every PBXGroup in the PBXGroup section and return the id of the first group
    /// whose `children = (...)` list contains a `.swift` file reference. This is project-name
    /// agnostic — it works for `LatticeTplAppApp.swift`, `CapBenchApp.swift`, or any other name.
    static func findSourceGroupID(in pbx: String) throws -> String {
        guard let pbxGroupEnd = pbx.range(of: "/* End PBXGroup section */") else {
            throw EntitlementsWiringError.noSourceGroup
        }
        let groupSection = String(pbx[..<pbxGroupEnd.lowerBound])
        guard let pbxGroupBeginRange = groupSection.range(of: "/* Begin PBXGroup section */") else {
            throw EntitlementsWiringError.noSourceGroup
        }
        let section = String(groupSection[pbxGroupBeginRange.upperBound...])

        // Walk each PBXGroup block. Return the id of the first one whose children list holds a
        // `.swift` reference. In pbxproj a child looks like `<id> /* Name.swift */,`, so the
        // closing comment text is `.swift */`.
        var searchStart = section.startIndex
        while searchStart < section.endIndex,
              let groupOpen = section[searchStart...].range(of: "= {") {
            // Capture the id preceding `= {`.
            let prefix = section[searchStart..<groupOpen.lowerBound]
            guard let id = hexIDs(in: String(prefix)).last else {
                searchStart = groupOpen.upperBound
                continue
            }
            // Find this group's closing brace.
            guard let closeRange = closingBrace(in: section, from: groupOpen.upperBound) else {
                break
            }
            let block = String(section[groupOpen.upperBound..<closeRange.lowerBound])
            if block.contains("isa = PBXGroup;"),
               let childrenRange = block.range(of: "children = (") {
                let afterParen = block[childrenRange.upperBound...]
                if let closeParen = afterParen.range(of: ")") {
                    let children = String(afterParen[..<closeParen.lowerBound])
                    // Match any swift source in the children list. The pbxproj comment for a swift
                    // file ends with `.swift */`, e.g. `/* CapBenchApp.swift */`.
                    if children.contains(".swift */") {
                        return id
                    }
                }
            }
            searchStart = closeRange.upperBound
        }
        throw EntitlementsWiringError.noSourceGroup
    }

    /// Inserts an entry line into the `files = (...)` list of the build phase identified by `phaseID`.
    ///
    /// Throws `EntitlementsWiringError.resourcesPhaseFilesNotFound` if the phase block, its
    /// opening `{`, or its `files = (` list cannot be found. Never silently returns the input
    /// unchanged — wiring must either complete or fail loudly.
    static func addToBuildPhaseFiles(
        _ phaseID: String,
        buildFileID: String,
        comment: String,
        in pbx: String
    ) throws -> String {
        var out = pbx
        guard let phaseBlockRange = out.range(of: "\t\t\(phaseID) /* Resources */ = {") else {
            throw EntitlementsWiringError.resourcesPhaseFilesNotFound
        }
        let region = out[phaseBlockRange.upperBound...]
        guard let filesRange = region.range(of: "files = (") else {
            throw EntitlementsWiringError.resourcesPhaseFilesNotFound
        }
        // Insert the new entry right after `files = (` so the new file appears first.
        let insertion = "\n\t\t\t\t\(buildFileID) /* \(comment) */,"
        out.insert(contentsOf: insertion, at: filesRange.upperBound)
        return out
    }

    /// Inserts an entry line into the `children = (...)` list of the group identified by `groupID`.
    ///
    /// Throws `EntitlementsWiringError.groupChildrenNotFound` if the group block, its opening
    /// `{`, or its `children = (` list cannot be found. Never silently returns the input
    /// unchanged — wiring must either complete or fail loudly.
    static func addToGroupChildren(
        _ groupID: String,
        fileRefID: String,
        comment: String,
        in pbx: String
    ) throws -> String {
        var out = pbx
        guard let groupRange = out.range(of: "\t\t\(groupID) /* ") else {
            throw EntitlementsWiringError.groupChildrenNotFound
        }
        let region = out[groupRange.upperBound...]
        guard let openBrace = region.range(of: "= {") else {
            throw EntitlementsWiringError.groupChildrenNotFound
        }
        let afterBrace = out[openBrace.upperBound...]
        guard let childrenRange = afterBrace.range(of: "children = (") else {
            throw EntitlementsWiringError.groupChildrenNotFound
        }
        // childrenRange.upperBound is a valid index into `out`.
        let insertion = "\n\t\t\t\t\(fileRefID) /* \(comment) */,"
        out.insert(contentsOf: insertion, at: childrenRange.upperBound)
        return out
    }

    /// Returns the range of the matching `}` for an already-consumed opening `{`.
    ///
    /// `start` must point immediately *after* an opening `{` that has just been matched. The scan
    /// begins at `depth = 1` (counting that consumed brace) and returns the index of the brace that
    /// brings depth back to 0. The returned range covers that single closing brace.
    private static func closingBrace(in s: String, from start: String.Index) -> Range<String.Index>? {
        var depth = 1
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return i..<s.index(after: i)
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

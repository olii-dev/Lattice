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
    ///
    /// The anchor requires a line start (newline + exactly two tabs) so child *references* to the
    /// same id deeper inside other blocks (e.g. `buildPhases = (...)` entries) don't match.
    static func blockRange(forConfigurationID id: String, in pbx: String) -> Range<String.Index>? {
        let anchor = "\n\t\t\(id) /*"
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
            // Replace only when the setting line actually exists — an unchanged value
            // produces an identical string, which must not be mistaken for "no match".
            if regex.numberOfMatches(in: block, options: [], range: full) > 0 {
                let replacement = "\t\t\t\t\(key) = \(value);"
                return regex.stringByReplacingMatches(in: block, options: [], range: full, withTemplate: replacement)
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

    // MARK: - Widget extension target

    enum WidgetExtensionError: Error, CustomStringConvertible {
        case noProjectObject
        case noMainGroup
        case noProductsGroup
        case noAppTargetBuildPhases
        case noAppBundleIdentifier
        case sectionInsertionFailed(String)

        var description: String {
            switch self {
            case .noProjectObject: return "Could not locate the root Project object in pbxproj."
            case .noMainGroup: return "Could not locate the main group in pbxproj."
            case .noProductsGroup: return "Could not locate the Products group in pbxproj."
            case .noAppTargetBuildPhases: return "Could not locate the app target's buildPhases list."
            case .noAppBundleIdentifier: return "Could not read PRODUCT_BUNDLE_IDENTIFIER from the app target."
            case .sectionInsertionFailed(let name): return "Could not insert into pbxproj section: \(name)."
            }
        }
    }

    /// Idempotently adds a WidgetKit app-extension target (`<AppName>Widgets`) to the project:
    /// group + file references, Sources/Frameworks phases, Debug/Release configurations,
    /// the native target, an app-target embed phase, and the target dependency. The caller is
    /// responsible for writing the extension's source files and Info.plist on disk.
    static func addWidgetExtension(in pbx: String, appName: String) throws -> String {
        // Idempotency: an extension target already present → nothing to do.
        if pbx.contains("productType = \"com.apple.product-type.app-extension\"") {
            return pbx
        }

        let extName = "\(appName)Widgets"

        // IDs up front.
        let existing = Set(hexIDs(in: pbx))
        func nextID() -> String {
            var id = generateUniqueHexID(avoiding: existing)
            while existing.contains(id) {
                id = generateUniqueHexID(avoiding: existing)
            }
            return id
        }
        let groupID = nextID()
        let swiftFileRefID = nextID()
        let plistFileRefID = nextID()
        let swiftBuildFileID = nextID()
        let sourcesPhaseID = nextID()
        let frameworksPhaseID = nextID()
        let debugConfigID = nextID()
        let releaseConfigID = nextID()
        let configListID = nextID()
        let targetID = nextID()
        let productRefID = nextID()
        let productBuildFileID = nextID()
        let embedPhaseID = nextID()
        let proxyID = nextID()
        let dependencyID = nextID()

        // App facts.
        guard let configIDs = applicationTargetConfigurationIDs(in: pbx),
              let firstConfigID = configIDs.first,
              let appConfigRange = blockRange(forConfigurationID: firstConfigID, in: pbx)
        else {
            throw WidgetExtensionError.noProjectObject
        }
        let appConfigBlock = String(pbx[appConfigRange])
        func setting(_ key: String) -> String? {
            guard let raw = extractBuildSettingValueRaw(appConfigBlock, key: key) else { return nil }
            let v = stripQuotes(raw)
            return v.isEmpty ? nil : v
        }
        guard let appBundleID = setting("PRODUCT_BUNDLE_IDENTIFIER") else {
            throw WidgetExtensionError.noAppBundleIdentifier
        }
        let deploymentKey = setting("IPHONEOS_DEPLOYMENT_TARGET") != nil
            ? "IPHONEOS_DEPLOYMENT_TARGET" : "MACOSX_DEPLOYMENT_TARGET"
        let deploymentTarget = setting(deploymentKey) ?? "26.0"
        let deviceFamily = setting("TARGETED_DEVICE_FAMILY") ?? "1,2"
        let swiftVersion = setting("SWIFT_VERSION") ?? "5.0"

        var out = pbx

        // 1. PBXBuildFile entries.
        out = try insertIntoSection(
            out, section: "PBXBuildFile",
            entries: [
                "\t\t\(swiftBuildFileID) /* \(extName)Bundle.swift in Sources */ = {isa = PBXBuildFile; fileRef = \(swiftFileRefID) /* \(extName)Bundle.swift */; };",
                "\t\t\(productBuildFileID) /* \(extName).appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = \(productRefID) /* \(extName).appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };",
            ]
        )

        // 2. PBXFileReference entries.
        out = try insertIntoSection(
            out, section: "PBXFileReference",
            entries: [
                "\t\t\(swiftFileRefID) /* \(extName)Bundle.swift */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = \(extName)Bundle.swift; sourceTree = \"<group>\"; };",
                "\t\t\(plistFileRefID) /* Info.plist */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };",
                "\t\t\(productRefID) /* \(extName).appex */ = {isa = PBXFileReference; explicitFileType = \"wrapper.appex\"; includeInIndex = 0; path = \(extName).appex; sourceTree = BUILT_PRODUCTS_DIR; };",
            ]
        )

        // 3. Phases.
        out = try insertIntoSection(
            out, section: "PBXFrameworksBuildPhase",
            entries: [
                "\t\t\(frameworksPhaseID) /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};",
            ]
        )
        out = try insertIntoSection(
            out, section: "PBXSourcesBuildPhase",
            entries: [
                "\t\t\(sourcesPhaseID) /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t\(swiftBuildFileID) /* \(extName)Bundle.swift in Sources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};",
            ]
        )

        // 4. Copy-files (embed) phase — section may not exist yet in a fresh template.
        let embedSection = "\n/* Begin PBXCopyFilesBuildPhase section */\n"
            + "\t\t\(embedPhaseID) /* Embed Foundation Extensions */ = {\n"
            + "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
            + "\t\t\tbuildActionMask = 2147483647;\n"
            + "\t\t\tdstPath = \"\";\n"
            + "\t\t\tdstSubfolderSpec = 13;\n"
            + "\t\t\tfiles = (\n"
            + "\t\t\t\t\(productBuildFileID) /* \(extName).appex in Embed Foundation Extensions */,\n"
            + "\t\t\t);\n"
            + "\t\t\tname = \"Embed Foundation Extensions\";\n"
            + "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            + "\t\t};\n"
            + "/* End PBXCopyFilesBuildPhase section */\n"
        out = try appendNewSection(out, sectionText: embedSection)

        // 5. Configurations + list.
        func configBlock(_ id: String, _ name: String) -> String {
            "\t\t\(id) /* \(name) */ = {\n"
                + "\t\t\tisa = XCBuildConfiguration;\n"
                + "\t\t\tbuildSettings = {\n"
                + "\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
                + "\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
                + "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n"
                + "\t\t\t\t\(deploymentKey) = \(deploymentTarget);\n"
                + "\t\t\t\tINFOPLIST_FILE = \(extName)/Info.plist;\n"
                + "\t\t\t\tMARKETING_VERSION = 1.0;\n"
                + "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \"\(appBundleID).widgets\";\n"
                + "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
                + "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n"
                + "\t\t\t\tSWIFT_VERSION = \(swiftVersion);\n"
                + "\t\t\t\tTARGETED_DEVICE_FAMILY = \"\(deviceFamily)\";\n"
                + "\t\t\t};\n"
                + "\t\t\tname = \(name);\n"
                + "\t\t};"
        }
        let configEntries = configBlock(debugConfigID, "Debug")
            + "\n" + configBlock(releaseConfigID, "Release")
        out = try insertIntoSection(out, section: "XCBuildConfiguration", entries: [configEntries])

        out = try insertIntoSection(
            out, section: "XCConfigurationList",
            entries: [
                "\t\t\(configListID) /* Build configuration list for PBXNativeTarget \"\(extName)\" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t\(debugConfigID) /* Debug */,\n\t\t\t\t\(releaseConfigID) /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};",
            ]
        )

        // 6. Native target.
        out = try insertIntoSection(
            out, section: "PBXNativeTarget",
            entries: [
                "\t\t\(targetID) /* \(extName) */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = \(configListID) /* Build configuration list for PBXNativeTarget \"\(extName)\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t\(sourcesPhaseID) /* Sources */,\n\t\t\t\t\(frameworksPhaseID) /* Frameworks */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t\(dependencyID) /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = \(extName);\n\t\t\tproductName = \(extName);\n\t\t\tproductReference = \(productRefID) /* \(extName).appex */;\n\t\t\tproductReferenceType = \"com.apple.product-type.app-extension\";\n\t\t\tproductType = \"com.apple.product-type.app-extension\";\n\t\t};",
            ]
        )

        // 7. Proxy + dependency (sections may not exist in a fresh template).
        guard let projectObjectID = rootProjectObjectID(in: out) else {
            throw WidgetExtensionError.noProjectObject
        }
        let proxySection = "\n/* Begin PBXContainerItemProxy section */\n"
            + "\t\t\(proxyID) /* PBXContainerItemProxy */ = {\n"
            + "\t\t\tisa = PBXContainerItemProxy;\n"
            + "\t\t\tcontainerPortal = \(projectObjectID) /* Project object */;\n"
            + "\t\t\tproxyType = 1;\n"
            + "\t\t\tremoteGlobalIDString = \(targetID);\n"
            + "\t\t\tremoteInfo = \(extName);\n"
            + "\t\t};\n"
            + "/* End PBXContainerItemProxy section */\n"
        out = try appendNewSection(out, sectionText: proxySection)

        let dependencySection = "\n/* Begin PBXTargetDependency section */\n"
            + "\t\t\(dependencyID) /* PBXTargetDependency */ = {\n"
            + "\t\t\tisa = PBXTargetDependency;\n"
            + "\t\t\ttarget = \(targetID);\n"
            + "\t\t\ttargetProxy = \(proxyID) /* PBXContainerItemProxy */;\n"
            + "\t\t};\n"
            + "/* End PBXTargetDependency section */\n"
        out = try appendNewSection(out, sectionText: dependencySection)

        // 8. Groups: widgets group + attach to main group; appex into Products group.
        out = try insertIntoSection(
            out, section: "PBXGroup",
            entries: [
                "\t\t\(groupID) /* \(extName) */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t\(swiftFileRefID) /* \(extName)Bundle.swift */,\n\t\t\t\t\(plistFileRefID) /* Info.plist */,\n\t\t\t);\n\t\t\tpath = \(extName);\n\t\t\tsourceTree = \"<group>\";\n\t\t};",
            ]
        )
        out = try appendToGroupChildren(pbx: out, groupID: try mainGroupID(in: out), childLine: "\(groupID) /* \(extName) */,")
        out = try appendToGroupChildren(pbx: out, groupID: try productsGroupID(in: out), childLine: "\(productRefID) /* \(extName).appex */,")

        // 9. Register the target in the Project object.
        guard let targetsRange = out.range(of: "targets = (\n") else {
            throw WidgetExtensionError.noProjectObject
        }
        out.insert(contentsOf: "\t\t\t\t\(targetID) /* \(extName) */,\n", at: targetsRange.upperBound)

        // 10. Embed phase into the app target's buildPhases.
        out = try insertEmbedPhaseIntoAppTarget(out, embedPhaseID: embedPhaseID, comment: "Embed Foundation Extensions")

        return out
    }

    // MARK: - pbxproj insertion helpers

    /// Inserts entry lines before the End marker of an existing section.
    private static func insertIntoSection(_ pbx: String, section: String, entries: [String]) throws -> String {
        let endMarker = "/* End \(section) section */"
        guard let endRange = pbx.range(of: endMarker) else {
            throw WidgetExtensionError.sectionInsertionFailed(section)
        }
        let insertion = entries.joined(separator: "\n") + "\n"
        var out = pbx
        out.insert(contentsOf: insertion, at: endRange.lowerBound)
        return out
    }

    /// Appends a brand-new section (used for sections the template lacks).
    private static func appendNewSection(_ pbx: String, sectionText: String) throws -> String {
        guard let finalBrace = pbx.lastIndex(of: "}") else {
            throw WidgetExtensionError.sectionInsertionFailed(sectionText)
        }
        var out = pbx
        out.insert(contentsOf: "\n" + sectionText, at: finalBrace)
        return out
    }

    private static func rootProjectObjectID(in pbx: String) -> String? {
        let pattern = "\t\t([0-9A-Fa-f]{24}) /\\* Project object \\*/ = \\{"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = pbx as NSString
        let match = regex.firstMatch(in: pbx, range: NSRange(location: 0, length: ns.length))
        guard let match, match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Extracts the 24-hex id assigned to a root-object property like `mainGroup = <id> /* ... */;`.
    private static func rootObjectReferenceID(in pbx: String, label: String) throws -> String {
        guard let range = pbx.range(of: label) else {
            throw WidgetExtensionError.noMainGroup
        }
        let tail = String(pbx[range.upperBound...].prefix(120))
        guard let id = hexIDs(in: tail).first, id.count == 24 else {
            throw WidgetExtensionError.noMainGroup
        }
        return id
    }

    private static func mainGroupID(in pbx: String) throws -> String {
        try rootObjectReferenceID(in: pbx, label: "mainGroup = ")
    }

    private static func productsGroupID(in pbx: String) throws -> String {
        do {
            return try rootObjectReferenceID(in: pbx, label: "productRefGroup = ")
        } catch {
            throw WidgetExtensionError.noProductsGroup
        }
    }

    /// Appends a child line to `children = (` list of the given group.
    private static func appendToGroupChildren(pbx: String, groupID: String, childLine: String) throws -> String {
        // Anchor on the definition line (newline + two tabs + id); child references
        // are indented deeper and don't match.
        let anchor = "\n\t\t\(groupID)"
        guard let groupStart = pbx.range(of: anchor) else {
            throw WidgetExtensionError.noMainGroup
        }
        guard let brace = pbx[groupStart.upperBound...].firstIndex(of: "{") else {
            throw WidgetExtensionError.noMainGroup
        }
        guard let childrenRange = pbx[brace...].range(of: "children = (\n") else {
            throw WidgetExtensionError.noMainGroup
        }
        var out = pbx
        out.insert(contentsOf: "\t\t\t\t\(childLine)\n", at: childrenRange.upperBound)
        return out
    }

    /// Inserts the embed phase into the app target's `buildPhases = (` list.
    private static func insertEmbedPhaseIntoAppTarget(
        _ pbx: String, embedPhaseID: String, comment: String
    ) throws -> String {
        guard let productTypeRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let head = pbx[..<productTypeRange.lowerBound]
        guard let blockOpen = head.range(of: "= {", options: .backwards) else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        guard let phasesRange = pbx[blockOpen.upperBound...].range(of: "buildPhases = (\n") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        var out = pbx
        out.insert(contentsOf: "\t\t\t\t\(embedPhaseID) /* \(comment) */,\n", at: phasesRange.upperBound)
        return out
    }

    /// Raw (possibly quoted) build-setting value inside a config block.
    private static func extractBuildSettingValueRaw(_ block: String, key: String) -> String? {
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = block as NSString
        guard let match = regex.firstMatch(
            in: block, range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    /// Registers a Swift source file inside the (first) app-extension target: file reference,
    /// build file, and an entry in the extension's Sources phase. Idempotent — a file whose
    /// reference already exists is left untouched.
    static func addSourceFileToAppExtension(
        in pbx: String, extFolderName: String, fileName: String
    ) throws -> String {
        // Idempotency: the file reference already exists → nothing to do.
        if pbx.contains("path = \(fileName);") {
            return pbx
        }

        let existing = Set(hexIDs(in: pbx))
        func nextID() -> String {
            var id = generateUniqueHexID(avoiding: existing)
            while existing.contains(id) {
                id = generateUniqueHexID(avoiding: existing)
            }
            return id
        }
        let fileRefID = nextID()
        let buildFileID = nextID()

        var out = pbx
        out = try insertIntoSection(
            out, section: "PBXBuildFile",
            entries: [
                "\t\t\(buildFileID) /* \(fileName) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRefID) /* \(fileName) */; };",
            ]
        )
        out = try insertIntoSection(
            out, section: "PBXFileReference",
            entries: [
                "\t\t\(fileRefID) /* \(fileName) */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = \(fileName); sourceTree = \"<group>\"; };",
            ]
        )

        // Attach the file reference to the extension group.
        let groupAnchor = "\n\t\t\tpath = \(extFolderName);"
        guard let groupLineRange = out.range(of: groupAnchor) else {
            throw WidgetExtensionError.sectionInsertionFailed("extension group for \(extFolderName)")
        }
        // Walk back to this group's `children = (` — it precedes `path` in the group block.
        let head = out[..<groupLineRange.lowerBound]
        guard let childrenRange = head.range(of: "children = (\n", options: .backwards) else {
            throw WidgetExtensionError.sectionInsertionFailed("children list for \(extFolderName)")
        }
        out.insert(contentsOf: "\t\t\t\t\(fileRefID) /* \(fileName) */,\n", at: childrenRange.upperBound)

        // Find the extension target's Sources phase and add the build file.
        guard let extTargetRange = out.range(of: "productType = \"com.apple.product-type.app-extension\";") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let targetHead = out[..<extTargetRange.lowerBound]
        guard let targetBlockOpen = targetHead.range(of: "= {", options: .backwards) else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        // The target block ends before the productType line; scan from the block open to it.
        let targetBlockText = String(out[targetBlockOpen.upperBound..<extTargetRange.lowerBound])
        guard let phasesRange = targetBlockText.range(of: "buildPhases = (") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let afterPhases = targetBlockText[phasesRange.upperBound...]
        guard let closeParen = afterPhases.range(of: ");") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let phaseIDs = hexIDs(in: String(afterPhases[..<closeParen.lowerBound]))

        var sourcesPhaseBlockRange: Range<String.Index>?
        for phaseID in phaseIDs {
            guard let range = blockRange(forConfigurationID: phaseID, in: out) else { continue }
            let block = String(out[range])
            if block.contains("isa = PBXSourcesBuildPhase;") {
                sourcesPhaseBlockRange = range
                break
            }
        }
        guard let sourcesRange = sourcesPhaseBlockRange else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let sourcesBlock = String(out[sourcesRange])
        guard let filesRange = sourcesBlock.range(of: "files = (\n") else {
            throw WidgetExtensionError.noAppTargetBuildPhases
        }
        let offset = sourcesBlock.distance(from: sourcesBlock.startIndex, to: filesRange.upperBound)
        let insertionIndex = out.index(sourcesRange.lowerBound, offsetBy: offset)
        out.insert(contentsOf: "\t\t\t\t\(buildFileID) /* \(fileName) in Sources */,\n", at: insertionIndex)

        return out
    }
}

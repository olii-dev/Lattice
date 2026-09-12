import Foundation

/// The result of applying a capability to a project.
struct CapabilityApplyResult {
    /// File URLs the applicator wrote to during this apply (deduplicated).
    /// A file is included whenever the applicator wrote it, even if the write was idempotent
    /// (content unchanged) — this reflects "files this capability is responsible for".
    let changedFiles: [URL]
    /// Keys (entitlement or Info.plist) that were already set before this apply, so the
    /// applicator did not need to add them. Used to detect idempotent re-applies.
    let alreadyPresent: [String]
    /// The capability's provisioning notes, if any, to surface to the user as manual steps.
    let manualSteps: String?
}

/// The result of removing a capability from a project.
///
/// `remove` strips only this capability's keys (entitlement keys, Info.plist keys, and the
/// corresponding `INFOPLIST_KEY_*` build settings) without touching other capabilities that may
/// share the same files. The entitlements file itself is never deleted.
struct CapabilityRemoveResult {
    /// File URLs the remover wrote to during this remove, deduplicated. A file appears here only
    /// when at least one of its keys was actually removed (idempotent re-removes touch nothing).
    let changedFiles: [URL]
    /// Keys (entitlement or Info.plist) that were actually present and have been stripped.
    /// Empty on an idempotent re-remove of an already-removed capability.
    let removedKeys: [String]
    /// The capability's provisioning notes, surfaced for reference even on removal.
    let manualSteps: String?
}

/// Errors thrown by `CapabilityApplicator`.
enum CapabilityApplicatorError: LocalizedError {
    case noXcodeProject
    case noApplicationTarget
    case unknownCapability(String)
    case missingParameter(String)
    case entitlementsWriteFailed(String)
    case plistWriteFailed(String)
    case pbxprojParseFailure(String)
    case notApplicableToPlatform(String, ApplePlatform)

    var errorDescription: String? {
        switch self {
        case .noXcodeProject:
            return "No Xcode project found in the given folder."
        case .noApplicationTarget:
            return "Could not find an application target in the Xcode project."
        case .unknownCapability(let id):
            return "Unknown capability id: \(id)."
        case .missingParameter(let name):
            return "Missing required parameter: \(name)."
        case .entitlementsWriteFailed(let msg):
            return "Failed to write entitlements file: \(msg)."
        case .plistWriteFailed(let msg):
            return "Failed to write Info.plist: \(msg)."
        case .pbxprojParseFailure(let msg):
            return "Could not parse project.pbxproj: \(msg)."
        case .notApplicableToPlatform(let capId, let platform):
            return "Capability '\(capId)' is not applicable to \(platform.rawValue)."
        }
    }
}

/// Turns a catalog entry (`AppleCapability`) into real file changes: entitlements plist,
/// Info.plist, and `project.pbxproj` build settings. Idempotent — re-applying the same
/// capability with the same parameters is a no-op on file contents.
///
/// Integrates `AppleCapabilityCatalog` (Task 3) with `PbxprojEditor` (Tasks 1-2).
enum CapabilityApplicator {

    // MARK: - Entry points

    /// Primary entry point. Looks up the capability by id and applies it.
    /// Used by the tool executor and UI. Throws `unknownCapability` for unknown ids.
    static func apply(
        capabilityId: String,
        to projectRoot: URL,
        parameters: [String: Any]
    ) async throws -> CapabilityApplyResult {
        guard let capability = AppleCapabilityCatalog.capability(id: capabilityId) else {
            throw CapabilityApplicatorError.unknownCapability(capabilityId)
        }
        return try await apply(capability: capability, to: projectRoot, parameters: parameters)
    }

    /// Convenience for already-resolved capabilities (used by tests). Skips the id lookup.
    static func apply(
        capability: AppleCapability,
        to projectRoot: URL,
        parameters: [String: Any]
    ) async throws -> CapabilityApplyResult {
        try await applyInternal(capability: capability, projectRoot: projectRoot, parameters: parameters)
    }

    // MARK: - Core logic

    private static func applyInternal(
        capability: AppleCapability,
        projectRoot: URL,
        parameters: [String: Any]
    ) async throws -> CapabilityApplyResult {
        // 2. Locate the project and read the pbxproj.
        let projURL = try findXcodeProj(projectRoot: projectRoot)
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        var pbxText = try String(contentsOf: pbxPath, encoding: .utf8)
        let originalPbx = pbxText

        var changedFiles: Set<URL> = []
        var alreadyPresent: [String] = []

        // Resolve the app target name once; used by entitlements wiring and seed files.
        let appName = try appNameFromPbxproj(pbxText)

        // 3. Resolve placeholders.
        let resolvedEntitlements = resolveEntitlements(capability.entitlements, parameters: parameters)
        let resolvedPlistEntries = resolvePlistEntries(capability.infoPlistKeys, parameters: parameters)

        // 4. Entitlements.
        if !resolvedEntitlements.isEmpty {
            let entRelPath = "\(appName)/\(appName).entitlements"
            let entURL = try ensureEntitlementsFile(pbxText: &pbxText, projectRoot: projectRoot, relPath: entRelPath)
            let mergeResult = try mergeEntitlements(into: entURL, entries: resolvedEntitlements)
            alreadyPresent.append(contentsOf: mergeResult.alreadyPresent)
            changedFiles.insert(entURL)
        }

        // 5. Info.plist entries.
        let plistChangedFiles = try applyPlistEntries(
            resolvedPlistEntries,
            projectRoot: projectRoot,
            pbxText: &pbxText
        )
        changedFiles.formUnion(plistChangedFiles)

        // 5.5 Capability-specific pre-seed pbxproj surgery: live activities need a
        // widget extension target to live in — create it (with the widget bundle seed)
        // when no extension exists yet.
        let hadExtensionTarget = pbxText.contains("productType = \"com.apple.product-type.app-extension\"")
        if capability.id == "live_activities", !hadExtensionTarget {
            try writeSeedFiles(
                AppleCapabilityCatalog.widgets.seedFiles,
                appName: appName, projectRoot: projectRoot, into: &changedFiles
            )
        }

        // 5.6 Seed files — created only when missing; existing files are never touched
        // (they may contain user edits by now) and removal never deletes them.
        try writeSeedFiles(
            capability.seedFiles,
            appName: appName, projectRoot: projectRoot, into: &changedFiles
        )

        // 5.7 Capability-specific pbxproj surgery (beyond build settings).
        if capability.id == "widgets" {
            pbxText = try PbxprojEditor.addWidgetExtension(in: pbxText, appName: appName)
        }
        if capability.id == "live_activities" {
            if !hadExtensionTarget {
                pbxText = try PbxprojEditor.addWidgetExtension(in: pbxText, appName: appName)
            }
            // Register the activity file in the extension's Sources phase (the bundle
            // seed is registered by addWidgetExtension; this file is not).
            pbxText = try PbxprojEditor.addSourceFileToAppExtension(
                in: pbxText,
                extFolderName: "\(appName)Widgets",
                fileName: "\(appName)LiveActivity.swift"
            )
        }

        // 6. Write the modified pbxproj if it changed.
        if pbxText != originalPbx {
            do {
                try pbxText.data(using: .utf8)?.write(to: pbxPath, options: .atomic)
            } catch {
                throw CapabilityApplicatorError.pbxprojParseFailure("Could not write project.pbxproj: \(error.localizedDescription)")
            }
            changedFiles.insert(pbxPath)
        }

        // 7. Return result.
        return CapabilityApplyResult(
            changedFiles: Array(changedFiles).sorted { $0.path < $1.path },
            alreadyPresent: alreadyPresent,
            manualSteps: capability.provisioningNotes
        )
    }

    // MARK: - Helpers — project location

    /// Writes seed files that don't yet exist (with `$(AppName)` resolution) and records
    /// them as changed. Existing files are never touched.
    private static func writeSeedFiles(
        _ seeds: [CapabilitySeedFile],
        appName: String,
        projectRoot: URL,
        into changedFiles: inout Set<URL>
    ) throws {
        for seed in seeds {
            let relPath = seed.relativePath
                .replacingOccurrences(of: "$(AppName)", with: appName)
            let seedURL = projectRoot.appendingPathComponent(relPath)
            guard !FileManager.default.fileExists(atPath: seedURL.path) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: seedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try seed.contents.write(to: seedURL, atomically: true, encoding: .utf8)
            } catch {
                throw CapabilityApplicatorError.entitlementsWriteFailed(
                    "Could not write seed file \(relPath): \(error.localizedDescription)"
                )
            }
            changedFiles.insert(seedURL)
        }
    }

    /// Finds the `.xcodeproj` in `projectRoot`, or returns `projectRoot` itself if it is a
    /// `.xcodeproj`. Throws `noXcodeProject` if none is found.
    private static func findXcodeProj(projectRoot: URL) throws -> URL {
        if projectRoot.pathExtension == "xcodeproj" {
            return projectRoot
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let projects = contents.filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = projects.first else {
            throw CapabilityApplicatorError.noXcodeProject
        }
        return first
    }

    /// Extracts the application target's name (the `name = X;` in the PBXNativeTarget application
    /// block). Throws `noApplicationTarget` if the app target or its name cannot be found.
    /// Internal so `CapabilityStatusChecker` can resolve `$(AppName)` seed-file paths too.
    static func appNameFromPbxproj(_ pbx: String) throws -> String {
        guard let productTypeRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        // Walk back to the target block opener (`= {`), then scan forward for `name = ...;`.
        let head = pbx[..<productTypeRange.lowerBound]
        guard let blockOpenRange = head.range(of: "= {", options: .backwards) else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        let region = pbx[blockOpenRange.upperBound..<productTypeRange.lowerBound]
        guard let nameRange = region.range(of: "name = ") else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        let afterName = region[nameRange.upperBound...]
        guard let semi = afterName.firstIndex(of: ";") else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        let raw = String(afterName[..<semi]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = PbxprojEditor.stripQuotes(raw)
        guard !name.isEmpty else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        return name
    }

    // MARK: - Helpers — entitlements

    /// Ensures the entitlements file is wired into the pbxproj (idempotent via
    /// `PbxprojEditor.ensureEntitlementsFileReference`) and exists on disk. Creates an empty
    /// plist (`<dict/>`) if the file does not yet exist. Returns the (possibly modified) pbxproj
    /// text and the on-disk entitlements URL.
    private static func ensureEntitlementsFile(
        pbxText: inout String,
        projectRoot: URL,
        relPath: String
    ) throws -> URL {
        let wiring: PbxprojEditor.EntitlementsWiringResult
        do {
            wiring = try PbxprojEditor.ensureEntitlementsFileReference(
                in: pbxText,
                relativePath: relPath
            )
        } catch {
            throw CapabilityApplicatorError.pbxprojParseFailure(
                "Could not wire entitlements file: \(error)"
            )
        }
        pbxText = wiring.modifiedPbx

        let entURL = projectRoot.appendingPathComponent(relPath)
        if !FileManager.default.fileExists(atPath: entURL.path) {
            // Create the parent directory if needed (e.g. `LatticeTplApp/`).
            let parent = entURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            // Write an empty plist: `<dict/>`.
            let emptyPlist: NSDictionary = [:]
            if !emptyPlist.write(to: entURL, atomically: true) {
                throw CapabilityApplicatorError.entitlementsWriteFailed(entURL.path)
            }
        }
        return entURL
    }

    /// Merges entitlement entries into the on-disk entitlements plist **idempotently**.
    /// - Array values merge uniquely (sorted).
    /// - Scalar (string/boolean) values overwrite if different.
    /// Tracks keys that were already present with an equal value (no change needed).
    private static func mergeEntitlements(
        into entURL: URL,
        entries: [EntitlementEntry]
    ) throws -> MergeResult {
        guard let plist = NSDictionary(contentsOf: entURL)?.mutableCopy() as? NSMutableDictionary
        else {
            throw CapabilityApplicatorError.entitlementsWriteFailed("Could not read \(entURL.path)")
        }

        var alreadyPresent: [String] = []
        var changedKeys: [String] = []

        for entry in entries {
            let newValue = entry.value.plistValue
            let existing = plist[entry.key]
            if let existing, isEqualPlistValue(existing, newValue) {
                alreadyPresent.append(entry.key)
                continue
            }
            // Merge arrays uniquely; otherwise overwrite.
            if let existingArr = existing as? [Any], let newArr = newValue as? [Any] {
                var merged = existingArr
                for item in newArr where !merged.contains(where: { isEqualPlistValue($0, item) }) {
                    merged.append(item)
                }
                // Sort string arrays for deterministic output.
                if let strings = merged as? [String] {
                    plist[entry.key] = strings.sorted()
                } else {
                    plist[entry.key] = merged
                }
            } else {
                plist[entry.key] = newValue
            }
            changedKeys.append(entry.key)
        }

        if !plist.write(to: entURL, atomically: true) {
            throw CapabilityApplicatorError.entitlementsWriteFailed("Could not write \(entURL.path)")
        }
        return MergeResult(changedKeys: changedKeys, alreadyPresent: alreadyPresent)
    }

    // MARK: - Helpers — Info.plist

    /// Locates an on-disk Info.plist via the `INFOPLIST_FILE` build setting of the app-target
    /// configs. Resolves `$(SRCROOT)`. Returns nil if no `INFOPLIST_FILE` setting is present.
    private static func findInfoPlist(projectRoot: URL, pbxText: String) throws -> URL? {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText) else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbxText) else { continue }
            let block = String(pbxText[range])
            if let raw = extractBuildSettingValue(block, key: "INFOPLIST_FILE") {
                let trimmed = PbxprojEditor.stripQuotes(raw)
                if !trimmed.isEmpty {
                    return resolveInfoPlistURL(projectRoot: projectRoot, setting: trimmed)
                }
            }
        }
        return nil
    }

    /// Applies resolved Info.plist entries. If an on-disk Info.plist exists, merges into it.
    /// Otherwise routes arrays to a freshly-created Info.plist file (with `INFOPLIST_FILE` set
    /// and `GENERATE_INFOPLIST_FILE = NO`), and scalars to `INFOPLIST_KEY_<key>` build settings.
    /// Returns the (possibly modified) pbxproj text and the set of files written.
    private static func applyPlistEntries(
        _ entries: [PlistEntry],
        projectRoot: URL,
        pbxText: inout String
    ) throws -> Set<URL> {
        var written: Set<URL> = []

        if entries.isEmpty {
            return written
        }

        if let existingPlist = try findInfoPlist(projectRoot: projectRoot, pbxText: pbxText) {
            let result = try mergeInfoPlistEntries(into: existingPlist, entries: entries)
            _ = result
            written.insert(existingPlist)
            return written
        }

        // No on-disk Info.plist. Separate array-valued entries (need a real plist file) from
        // scalars (can go into INFOPLIST_KEY_* build settings).
        var arrayEntries: [PlistEntry] = []
        var scalarEntries: [PlistEntry] = []
        for entry in entries {
            if entry.value is [Any] {
                arrayEntries.append(entry)
            } else {
                scalarEntries.append(entry)
            }
        }

        let appName = try appNameFromPbxproj(pbxText)
        let infoRelPath = "\(appName)/Info.plist"
        let infoURL = projectRoot.appendingPathComponent(infoRelPath)

        if !arrayEntries.isEmpty {
            // Create the Info.plist file (load existing if somehow present, else empty).
            let plist: NSMutableDictionary
            if FileManager.default.fileExists(atPath: infoURL.path),
               let existing = NSDictionary(contentsOf: infoURL)?.mutableCopy() as? NSMutableDictionary {
                plist = existing
            } else {
                let parent = infoURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                plist = NSMutableDictionary()
            }
            // We are about to flip GENERATE_INFOPLIST_FILE to NO and point Xcode at this file.
            // Carry over any existing INFOPLIST_KEY_* build settings so they are not silently
            // lost (Xcode stops honouring INFOPLIST_KEY_* once a real Info.plist takes over).
            // Existing explicit plist keys already on disk take precedence over these.
            let inherited = collectExistingInfoPlistKeySettings(pbxText: pbxText)
            for (key, value) in inherited where plist[key] == nil {
                plist[key] = value
            }
            for entry in arrayEntries {
                plist[entry.key] = entry.value
            }
            if !plist.write(to: infoURL, atomically: true) {
                throw CapabilityApplicatorError.plistWriteFailed("Could not write \(infoURL.path)")
            }
            written.insert(infoURL)
            // Set INFOPLIST_FILE and GENERATE_INFOPLIST_FILE = NO on every app-target config.
            pbxText = try setBuildSettingOnAllAppConfigs(
                pbxText, key: "INFOPLIST_FILE", value: PbxprojEditor.pbxEscape(infoRelPath)
            )
            pbxText = try setBuildSettingOnAllAppConfigs(
                pbxText, key: "GENERATE_INFOPLIST_FILE", value: "NO"
            )
        }

        for entry in scalarEntries {
            let stringValue: String
            if let s = entry.value as? String {
                stringValue = s
            } else if let b = entry.value as? Bool {
                stringValue = b ? "YES" : "NO"
            } else {
                stringValue = "\(entry.value)"
            }
            pbxText = try setBuildSettingOnAllAppConfigs(
                pbxText,
                key: "INFOPLIST_KEY_\(entry.key)",
                value: PbxprojEditor.pbxEscape(stringValue)
            )
        }

        return written
    }

    /// Merges Info.plist entries into an existing on-disk Info.plist **idempotently**.
    private static func mergeInfoPlistEntries(
        into infoURL: URL,
        entries: [PlistEntry]
    ) throws -> MergeResult {
        guard let plist = NSDictionary(contentsOf: infoURL)?.mutableCopy() as? NSMutableDictionary
        else {
            throw CapabilityApplicatorError.pbxprojParseFailure("Could not read \(infoURL.path)")
        }

        var alreadyPresent: [String] = []
        var changedKeys: [String] = []

        for entry in entries {
            let existing = plist[entry.key]
            if let existing, isEqualPlistValue(existing, entry.value) {
                alreadyPresent.append(entry.key)
                continue
            }
            if let existingArr = existing as? [Any], let newArr = entry.value as? [Any] {
                var merged = existingArr
                for item in newArr where !merged.contains(where: { isEqualPlistValue($0, item) }) {
                    merged.append(item)
                }
                if let strings = merged as? [String] {
                    plist[entry.key] = strings.sorted()
                } else {
                    plist[entry.key] = merged
                }
            } else {
                plist[entry.key] = entry.value
            }
            changedKeys.append(entry.key)
        }

        if !plist.write(to: infoURL, atomically: true) {
            throw CapabilityApplicatorError.plistWriteFailed("Could not write \(infoURL.path)")
        }
        return MergeResult(changedKeys: changedKeys, alreadyPresent: alreadyPresent)
    }

    /// Resolves `$(SRCROOT)`-style prefixes in an `INFOPLIST_FILE` setting value to an on-disk URL.
    private static func resolveInfoPlistURL(projectRoot: URL, setting: String) -> URL {
        var path = setting
        path = path.replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
        path = path.replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
    }

    /// Sets a build setting on every application-target XCBuildConfiguration block.
    private static func setBuildSettingOnAllAppConfigs(
        _ pbxText: String,
        key: String,
        value: String
    ) throws -> String {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText) else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        var out = pbxText
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: out) else {
                throw CapabilityApplicatorError.pbxprojParseFailure("Missing XCBuildConfiguration \(id).")
            }
            let block = String(out[range])
            let updated = PbxprojEditor.setOrInsertBuildSetting(block, key: key, value: value)
            out.replaceSubrange(range, with: updated)
        }
        return out
    }

    // MARK: - Placeholder resolution

    /// Resolves `EntitlementValue.placeholder("$(Name)")` entries against `parameters`.
    /// - `[String]` parameter → `.stringArray`
    /// - `String` parameter → `.string`
    /// - Missing parameter → the entry is **dropped** (not written). This is how optional /
    ///   parameterized entitlements are expressed.
    /// Non-placeholder values are kept verbatim.
    private static func resolveEntitlements(
        _ entries: [EntitlementEntry],
        parameters: [String: Any]
    ) -> [EntitlementEntry] {
        var resolved: [EntitlementEntry] = []
        for entry in entries {
            switch entry.value {
            case .placeholder(let token):
                let name = placeholderName(token)
                guard let value = parameters[name] else {
                    // Skip — missing parameter means this entitlement is omitted.
                    continue
                }
                if let arr = value as? [String] {
                    resolved.append(EntitlementEntry(key: entry.key, value: .stringArray(arr)))
                } else if let arr = value as? [Any] {
                    // Tolerate `[Any]` coming from untyped dictionaries; coerce to strings.
                    let strings = arr.compactMap { $0 as? String }
                    resolved.append(EntitlementEntry(key: entry.key, value: .stringArray(strings)))
                } else if let s = value as? String {
                    resolved.append(EntitlementEntry(key: entry.key, value: .string(s)))
                } else {
                    // Non-string scalar: coerce to string.
                    resolved.append(EntitlementEntry(key: entry.key, value: .string("\(value)")))
                }
            default:
                resolved.append(entry)
            }
        }
        return resolved
    }

    /// Resolves Info.plist entries whose value is a `String` starting with `$(` against
    /// `parameters`. Resolved arrays stay arrays, resolved scalars stay scalars. Missing
    /// parameters drop the entry. Non-placeholder values are kept verbatim.
    private static func resolvePlistEntries(
        _ entries: [PlistEntry],
        parameters: [String: Any]
    ) -> [PlistEntry] {
        var resolved: [PlistEntry] = []
        for entry in entries {
            if let s = entry.value as? String, s.hasPrefix("$(") {
                let name = placeholderName(s)
                guard let value = parameters[name] else {
                    continue
                }
                resolved.append(PlistEntry(key: entry.key, value: value))
            } else {
                resolved.append(entry)
            }
        }
        return resolved
    }

    /// Extracts the parameter name from a placeholder token: `"$(AppGroupIdentifier)"` →
    /// `"AppGroupIdentifier"`. Tolerates missing `$(` prefix.
    private static func placeholderName(_ token: String) -> String {
        var t = token
        if t.hasPrefix("$(") { t.removeFirst(2) }
        if t.hasSuffix(")") { t.removeLast() }
        return t
    }

    // MARK: - Build setting extraction & value comparison

    /// Regex-extracts the raw value of `key = value;` from a pbxproj config block.
    /// Returns the value substring (still quoted if it was quoted), or nil if not present.
    ///
    /// The leading lookbehind `(?<![A-Za-z0-9_])` ensures the key is not matched as a suffix of
    /// a longer setting name — e.g. querying `INFOPLIST_FILE` must not match inside
    /// `GENERATE_INFOPLIST_FILE = YES`.
    private static func extractBuildSettingValue(_ block: String, key: String) -> String? {
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: block, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collects every `INFOPLIST_KEY_<Key>` build setting from the app-target configs and returns
    /// them as a plist dictionary keyed by the suffix (`<Key>`). The `INFOPLIST_KEY_` prefix is
    /// Apple's mapping from a build setting to an Info.plist key. Values are coerced to plist
    /// types: quoted booleans `YES`/`NO` → Bool; everything else stays a string. Used when
    /// creating a fresh Info.plist so existing auto-generated keys survive the switch away from
    /// `GENERATE_INFOPLIST_FILE = YES`.
    private static func collectExistingInfoPlistKeySettings(pbxText: String) -> [String: Any] {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText) else {
            return [:]
        }
        var collected: [String: Any] = [:]
        let prefix = "INFOPLIST_KEY_"
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbxText) else { continue }
            let block = String(pbxText[range])
            guard let regex = try? NSRegularExpression(pattern: prefix + "([A-Za-z0-9_]+)\\s*=\\s*([^;]+);") else { continue }
            let ns = block as NSString
            regex.enumerateMatches(in: block, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 2 else { return }
                let key = ns.substring(with: match.range(at: 1))
                if collected[key] != nil { return } // first config wins; values should match across configs
                let raw = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                collected[key] = coerceInfoPlistKeyValue(raw)
            }
        }
        return collected
    }

    /// Coerces a raw pbxproj build-setting value string into the plist type Xcode would infer:
    /// `YES`/`NO` → Bool, anything else → String (quotes stripped).
    private static func coerceInfoPlistKeyValue(_ raw: String) -> Any {
        let unquoted = PbxprojEditor.stripQuotes(raw)
        switch unquoted {
        case "YES": return true
        case "NO": return false
        default: return unquoted
        }
    }

    /// Compares two plist values for equality across the types the applicator handles:
    /// strings, booleans, numbers, and arrays thereof.
    private static func isEqualPlistValue(_ lhs: Any, _ rhs: Any) -> Bool {
        // Booleans first — NSNumber boxing can make `false` compare equal to `0`.
        if let lb = toBool(lhs), let rb = toBool(rhs) {
            return lb == rb
        }
        if let ls = lhs as? String, let rs = rhs as? String {
            return ls == rs
        }
        if let ln = lhs as? NSNumber, let rn = rhs as? NSNumber {
            return ln == rn
        }
        if let la = lhs as? [Any], let ra = rhs as? [Any] {
            guard la.count == ra.count else { return false }
            for (x, y) in zip(la, ra) {
                if !isEqualPlistValue(x, y) { return false }
            }
            return true
        }
        return false
    }

    /// Coerces a plist value to `Bool` if it is genuinely boolean (bridged from NSNumber with
    /// `objCType` "c" and value 0/1, or a Swift `Bool`). Avoids treating `0`/`1` numbers as bools.
    private static func toBool(_ value: Any) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber, strcmp(n.objCType, "c") == 0 {
            return n.boolValue
        }
        return nil
    }

    // MARK: - Remove

    /// Removes a capability's file-side markers from the project: entitlement keys from the
    /// `.entitlements` plist, and Info.plist keys (from the on-disk `Info.plist`, or from the
    /// `INFOPLIST_KEY_*` build settings when the project uses `GENERATE_INFOPLIST_FILE = YES`).
    ///
    /// Safe by construction: only this capability's keys are touched, so other capabilities
    /// sharing the same files are unaffected. The entitlements file itself is **never** deleted —
    /// other capabilities or the pbxproj file reference may still need it (even an empty `<dict/>`
    /// is left in place). Likewise `INFOPLIST_FILE` / `GENERATE_INFOPLIST_FILE` are never unset.
    ///
    /// Idempotent: re-removing an already-removed capability reports `removedKeys == []` and
    /// writes nothing.
    static func remove(
        capabilityId: String,
        from projectRoot: URL
    ) async throws -> CapabilityRemoveResult {
        // 1. Look up the capability. Unknown id → throw.
        guard let capability = AppleCapabilityCatalog.capability(id: capabilityId) else {
            throw CapabilityApplicatorError.unknownCapability(capabilityId)
        }

        // 2. Locate the project and read the pbxproj.
        let projURL = try findXcodeProj(projectRoot: projectRoot)
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        var pbxText = try String(contentsOf: pbxPath, encoding: .utf8)
        let originalPbx = pbxText

        var changedFiles: Set<URL> = []
        var removedKeys: [String] = []

        let entitlementKeys = capability.entitlements.map { $0.key }
        let plistKeys = capability.infoPlistKeys.map { $0.key }

        // 3. Entitlements: only strip if the capability declares keys AND an entitlements file
        //    actually exists on disk. The file is never deleted, even if it ends up empty.
        if !entitlementKeys.isEmpty,
           let entURL = try findExistingEntitlementsFile(projectRoot: projectRoot, pbxText: pbxText) {
            let removed = try removeKeys(fromPlistAt: entURL, keys: entitlementKeys)
            if !removed.isEmpty {
                changedFiles.insert(entURL)
                removedKeys.append(contentsOf: removed)
            }
        }

        // 4. Info.plist keys.
        if !plistKeys.isEmpty {
            if let infoURL = try findInfoPlist(projectRoot: projectRoot, pbxText: pbxText) {
                // On-disk Info.plist: remove the keys from it directly.
                let removed = try removeKeys(fromPlistAt: infoURL, keys: plistKeys)
                if !removed.isEmpty {
                    changedFiles.insert(infoURL)
                    removedKeys.append(contentsOf: removed)
                }
            } else {
                // No on-disk Info.plist (GENERATE_INFOPLIST_FILE = YES): strip the
                // INFOPLIST_KEY_<key> build settings from every app-target config. Never unset
                // INFOPLIST_FILE / GENERATE_INFOPLIST_FILE — another capability may rely on them.
                var removedFromSettings: [String] = []
                for key in plistKeys {
                    let didRemove = try removeBuildSettingFromAllAppConfigs(
                        pbxText: &pbxText, key: "INFOPLIST_KEY_\(key)"
                    )
                    if didRemove { removedFromSettings.append(key) }
                }
                removedKeys.append(contentsOf: removedFromSettings)
            }
        }

        // 5. Write the modified pbxproj if it changed.
        if pbxText != originalPbx {
            do {
                try pbxText.data(using: .utf8)?.write(to: pbxPath, options: .atomic)
            } catch {
                throw CapabilityApplicatorError.pbxprojParseFailure(
                    "Could not write project.pbxproj: \(error.localizedDescription)"
                )
            }
            changedFiles.insert(pbxPath)
        }

        // 6. Return result.
        return CapabilityRemoveResult(
            changedFiles: Array(changedFiles).sorted { $0.path < $1.path },
            removedKeys: removedKeys,
            manualSteps: capability.provisioningNotes
        )
    }

    // MARK: - Remove helpers

    /// Locates an entitlements file that **exists on disk** by reading `CODE_SIGN_ENTITLEMENTS`
    /// from any application-target config and resolving the path (handles `$(SRCROOT)`).
    /// Returns nil when no setting is present or the resolved file does not exist on disk.
    private static func findExistingEntitlementsFile(
        projectRoot: URL,
        pbxText: String
    ) throws -> URL? {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText) else {
            return nil
        }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbxText) else { continue }
            let block = String(pbxText[range])
            if let raw = extractBuildSettingValue(block, key: "CODE_SIGN_ENTITLEMENTS") {
                let trimmed = PbxprojEditor.stripQuotes(raw)
                if !trimmed.isEmpty {
                    let url = resolveInfoPlistURL(projectRoot: projectRoot, setting: trimmed)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        return nil
    }

    /// Removes the given keys from an `NSDictionary`-backed plist file at `url`. Returns the subset
    /// of keys that were actually present (and therefore removed). Writes the modified plist back
    /// only when at least one key was removed. **Never deletes the file itself.**
    private static func removeKeys(fromPlistAt url: URL, keys: [String]) throws -> [String] {
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else {
            // File missing or unreadable: nothing to remove.
            return []
        }
        var removed: [String] = []
        for key in keys {
            if plist[key] != nil {
                plist.removeObject(forKey: key)
                removed.append(key)
            }
        }
        guard !removed.isEmpty else { return removed }
        if !plist.write(to: url, atomically: true) {
            throw CapabilityApplicatorError.plistWriteFailed("Could not write \(url.path)")
        }
        return removed
    }

    /// Removes the `\t\t\t\tkey = value;` line for `key` from every application-target config block
    /// in `pbxText`. Returns `true` when at least one block had the line removed. Mutates `pbxText`
    /// in place. This is the inverse of `setBuildSettingOnAllAppConfigs`.
    private static func removeBuildSettingFromAllAppConfigs(
        pbxText: inout String,
        key: String
    ) throws -> Bool {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText) else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        var anyRemoved = false
        var out = pbxText
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: out) else { continue }
            let block = String(out[range])
            let (updated, didRemove) = removeBuildSettingLine(block, key: key)
            if didRemove {
                anyRemoved = true
                out.replaceSubrange(range, with: updated)
            }
        }
        pbxText = out
        return anyRemoved
    }

    /// Removes a single `\t\t\t\tkey = value;` line from one config block — the inverse of
    /// `PbxprojEditor.setOrInsertBuildSetting`. Consumes the line's leading newline so no blank
    /// line is left behind. Returns the (possibly unchanged) block and a flag indicating whether a
    /// line was actually removed.
    ///
    /// Internal (not private) so the regex behavior can be locked in with direct unit tests — it's
    /// a pure function and the only realistic way to exercise the build-setting removal path is to
    /// call it directly.
    static func removeBuildSettingLine(_ block: String, key: String) -> (String, Bool) {
        // Match the leading newline + indent + key + ` = ` + value + `;`. Same indentation style as
        // `setOrInsertBuildSetting`. The value is `[^;\n]*` so the match stays on one line.
        let linePattern = "\\n\\t\\t\\t\\t"
            + NSRegularExpression.escapedPattern(for: key)
            + " = [^;\\n]*;"
        guard let regex = try? NSRegularExpression(pattern: linePattern, options: []) else {
            return (block, false)
        }
        let ns = block as NSString
        let full = NSRange(location: 0, length: ns.length)
        let replaced = regex.stringByReplacingMatches(
            in: block, options: [], range: full, withTemplate: ""
        )
        if replaced != block {
            return (replaced, true)
        }
        return (block, false)
    }
}

/// Internal result of an idempotent plist merge.
private struct MergeResult {
    /// Keys whose value was added or changed by this merge.
    let changedKeys: [String]
    /// Keys that were already present with an equal value (no change needed).
    let alreadyPresent: [String]
}

import Foundation

/// Read-only snapshot of which capabilities are active in a project.
struct CapabilityStatus {
    /// Capability ids whose file-side markers are present (entitlement keys in the
    /// `.entitlements` file and/or Info.plist keys in the on-disk plist or `INFOPLIST_KEY_*`
    /// build settings). Capabilities with no file-side markers (e.g. StoreKit) are undetectable
    /// and never appear here.
    let activeCapabilities: Set<String>
}

/// Scans a project's entitlements and Info.plist / build settings to determine which catalog
/// capabilities are currently active. Read-only — never writes.
///
/// A capability is **active** when all of its entitlement keys and Info.plist keys are
/// present, **or** when any of its seed files exists on disk (seed presence proves the
/// capability was applied even when optional parameters were never supplied).
enum CapabilityStatusChecker {

    /// Reports which catalog capabilities are currently active in the project at `projectRoot`.
    ///
    /// `projectRoot` may be either a directory containing an `.xcodeproj` or an `.xcodeproj`
    /// itself, matching `CapabilityApplicator`'s convention.
    static func check(projectRoot: URL) async throws -> CapabilityStatus {
        // 1. Locate the project and read the pbxproj text.
        let projURL = try findXcodeProj(projectRoot: projectRoot)
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        let pbxText = try String(contentsOf: pbxPath, encoding: .utf8)

        // 2-3. Load the on-disk dicts (either may be nil if absent).
        let entitlements = loadEntitlements(projectRoot: projectRoot, pbx: pbxText)
        let infoPlist = loadInfoPlist(projectRoot: projectRoot, pbx: pbxText)

        // Collect every INFOPLIST_KEY_<key> build setting present in app-target configs. A key
        // set this way satisfies a capability's plist-key requirement even without an on-disk plist.
        let infoPlistSettingKeys = collectInfoPlistKeySettings(pbx: pbxText)

        // 4. Evaluate each catalog capability.
        var active: Set<String> = []
        for capability in AppleCapabilityCatalog.all {
            let entKeys = capability.entitlements.map { $0.key }
            let plistKeys = capability.infoPlistKeys.map { $0.key }
            let hasEntPlistMarkers = !entKeys.isEmpty || !plistKeys.isEmpty
            let hasSeedMarkers = !capability.seedFiles.isEmpty

            // Undetectable: no markers of any kind (e.g. StoreKit).
            guard hasEntPlistMarkers || hasSeedMarkers else { continue }

            let entOK: Bool
            if entKeys.isEmpty {
                entOK = true
            } else if let entitlements {
                entOK = entKeys.allSatisfy { entitlements[$0] != nil }
            } else {
                entOK = false
            }

            let plistOK: Bool
            if plistKeys.isEmpty {
                plistOK = true
            } else {
                // Keys with unresolved placeholder parameters may legitimately be absent.
                plistOK = plistKeys.allSatisfy { key in
                    (infoPlist?[key] != nil) || infoPlistSettingKeys.contains(key)
                }
            }

            var isActive = hasEntPlistMarkers && entOK && plistOK

            // Seed files prove application even when optional parameters were never
            // supplied or entitlement/plist markers are absent (e.g. App Intents
            // without a Siri usage description).
            if !isActive, hasSeedMarkers {
                isActive = seedFileMarkerPresent(capability, projectRoot: projectRoot, pbx: pbxText)
            }

            if isActive {
                active.insert(capability.id)
            }
        }

        return CapabilityStatus(activeCapabilities: active)
    }

    // MARK: - Load helpers

    /// True when any of the capability's seed files exists on disk (resolving `$(AppName)`).
    private static func seedFileMarkerPresent(
        _ capability: AppleCapability,
        projectRoot: URL,
        pbx: String
    ) -> Bool {
        guard !capability.seedFiles.isEmpty else { return false }
        guard let appName = try? CapabilityApplicator.appNameFromPbxproj(pbx) else { return false }
        return capability.seedFiles.contains { seed in
            let rel = seed.relativePath.replacingOccurrences(of: "$(AppName)", with: appName)
            return FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(rel).path)
        }
    }

    /// Loads the project's `.entitlements` plist as a dictionary. Returns nil when no
    /// `CODE_SIGN_ENTITLEMENTS` setting is present, the resolved path does not exist, or the
    /// file cannot be read as a plist.
    private static func loadEntitlements(projectRoot: URL, pbx: String) -> [String: Any]? {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbx) else {
            return nil
        }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            guard let raw = extractValue(block, key: "CODE_SIGN_ENTITLEMENTS") else { continue }
            let trimmed = PbxprojEditor.stripQuotes(raw)
            guard !trimmed.isEmpty else { continue }
            let url = resolvePath(projectRoot: projectRoot, setting: trimmed)
            if FileManager.default.fileExists(atPath: url.path),
               let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    /// Loads the on-disk `Info.plist` as a dictionary, located via the app-target configs'
    /// `INFOPLIST_FILE` setting (resolving `$(SRCROOT)`). Returns nil when no setting is present
    /// or the file does not exist / cannot be read. Note: build settings may additionally carry
    /// `INFOPLIST_KEY_<key>` entries that are not on disk — those are collected separately.
    private static func loadInfoPlist(projectRoot: URL, pbx: String) -> [String: Any]? {
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbx) else {
            return nil
        }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            guard let raw = extractValue(block, key: "INFOPLIST_FILE") else { continue }
            let trimmed = PbxprojEditor.stripQuotes(raw)
            guard !trimmed.isEmpty else { continue }
            let url = resolvePath(projectRoot: projectRoot, setting: trimmed)
            if FileManager.default.fileExists(atPath: url.path),
               let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    /// Collects the set of `<key>` for every `INFOPLIST_KEY_<key> = value;` build setting present
    /// across all application-target configs. Mirrors the write path in `CapabilityApplicator`,
    /// which routes scalar plist values to `INFOPLIST_KEY_*` settings when there is no on-disk plist.
    private static func collectInfoPlistKeySettings(pbx: String) -> Set<String> {
        var keys: Set<String> = []
        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: pbx) else {
            return keys
        }
        let prefix = "INFOPLIST_KEY_"
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            // Walk every build-setting line in the block; for those whose key starts with the
            // INFOPLIST_KEY_ prefix, record the suffix as a plist key.
            let regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_])(INFOPLIST_KEY_[A-Za-z0-9_]+)\\s*=\\s*[^;]+;",
                options: []
            )
            let ns = block as NSString
            let full = NSRange(location: 0, length: ns.length)
            regex?.enumerateMatches(in: block, range: full) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let fullKey = ns.substring(with: match.range(at: 1))
                keys.insert(String(fullKey.dropFirst(prefix.count)))
            }
        }
        return keys
    }

    // MARK: - Build setting extraction & path resolution

    /// Regex-extracts the raw value of `key = value;` from a pbxproj config block.
    /// Returns the value substring (still quoted if it was quoted), or nil if not present.
    ///
    /// The leading lookbehind `(?<![A-Za-z0-9_])` ensures the key is not matched as a suffix of
    /// a longer setting name — e.g. querying `INFOPLIST_FILE` must not match inside
    /// `GENERATE_INFOPLIST_FILE = YES`. Mirrors `CapabilityApplicator.extractBuildSettingValue`.
    private static func extractValue(_ block: String, key: String) -> String? {
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: block, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves `$(SRCROOT)` / `${SRCROOT}` prefixes in a build-setting path value to an on-disk
    /// URL relative to `projectRoot`. Mirrors `CapabilityApplicator.resolveInfoPlistURL`.
    private static func resolvePath(projectRoot: URL, setting: String) -> URL {
        var path = setting
        path = path.replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
        path = path.replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
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
}

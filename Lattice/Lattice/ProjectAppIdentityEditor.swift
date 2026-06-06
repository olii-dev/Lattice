import Foundation

/// Editable app identity sourced from xcodebuild settings and mirrored into the Xcode project file.
struct ProjectAppIdentity: Equatable {
    var productName: String
    var displayName: String
    var marketingVersion: String
    var buildNumber: String
}

enum ProjectAppIdentityError: LocalizedError {
    case noXcodeProject
    case noApplicationTarget
    case parseFailure(String)
    case writeFailure(String)

    var errorDescription: String? {
        switch self {
        case .noXcodeProject:
            return "No Xcode project found in this folder."
        case .noApplicationTarget:
            return "Could not find an application target in the Xcode project."
        case .parseFailure(let msg):
            return msg
        case .writeFailure(let msg):
            return msg
        }
    }
}

enum ProjectAppIdentityEditor {
    private static func buildSettingsDump(projectRoot: URL) async throws -> String {
        let xcodeTarget = try SimulatorBuildRunner.resolveXcodeTarget(projectRoot: projectRoot)
        let schemes = try await SimulatorBuildRunner.listSchemes(target: xcodeTarget)
        guard let scheme = SimulatorBuildRunner.pickScheme(
            schemes: schemes,
            buildInfo: nil,
            projectRoot: projectRoot,
            xcodeTarget: xcodeTarget
        ) else {
            throw ProjectAppIdentityError.noXcodeProject
        }
        return try await SimulatorBuildRunner.showBuildSettings(
            target: xcodeTarget,
            scheme: scheme,
            projectRoot: projectRoot
        )
    }

    private static func value(for key: String, in settings: String) -> String? {
        for raw in settings.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Loads resolved build settings for the picked scheme (and Info.plist when present).
    static func load(projectRoot: URL) async throws -> ProjectAppIdentity {
        let settings = try await buildSettingsDump(projectRoot: projectRoot)

        var productName = stripQuotes(value(for: "PRODUCT_NAME", in: settings) ?? "")
        var display = stripQuotes(
            value(for: "INFOPLIST_KEY_CFBundleDisplayName", in: settings)
                ?? value(for: "INFOPLIST_KEY_CFBundleName", in: settings)
                ?? ""
        )
        var marketing = stripQuotes(value(for: "MARKETING_VERSION", in: settings) ?? "")
        var buildNum = stripQuotes(value(for: "CURRENT_PROJECT_VERSION", in: settings) ?? "")

        if let rawPlist = value(for: "INFOPLIST_FILE", in: settings),
           let plistURL = resolveInfoPlistURL(projectRoot: projectRoot, infoPlistSetting: rawPlist),
           let plistVals = readInfoPlistIdentity(at: plistURL) {
            if display.isEmpty, let d = plistVals.display { display = d }
            if marketing.isEmpty, let m = plistVals.shortVersion { marketing = m }
            if buildNum.isEmpty, let b = plistVals.build { buildNum = b }
        }

        return ProjectAppIdentity(
            productName: productName,
            displayName: display,
            marketingVersion: marketing,
            buildNumber: buildNum
        )
    }

    /// Resolved main-target `PRODUCT_BUNDLE_IDENTIFIER` (for inspector / UI).
    static func resolvedBundleIdentifier(projectRoot: URL) async throws -> String? {
        let settings = try await buildSettingsDump(projectRoot: projectRoot)
        let raw = value(for: "PRODUCT_BUNDLE_IDENTIFIER", in: settings) ?? ""
        let s = stripQuotes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return s.isEmpty ? nil : s
    }

    /// Writes into `project.pbxproj` and, when `INFOPLIST_FILE` exists on disk, updates that plist too.
    static func save(
        projectRoot: URL,
        identity: ProjectAppIdentity,
        bundleIdentifier: String? = nil,
        developmentTeam: String? = nil
    ) async throws {
        let settings = try await buildSettingsDump(projectRoot: projectRoot)
        try applyPbxprojIdentity(
            projectRoot: projectRoot,
            identity: identity,
            bundleIdentifier: bundleIdentifier,
            developmentTeam: developmentTeam
        )
        if let rawPlist = value(for: "INFOPLIST_FILE", in: settings),
           let plistURL = resolveInfoPlistURL(projectRoot: projectRoot, infoPlistSetting: rawPlist) {
            try mergeInfoPlist(at: plistURL, identity: identity)
        }
    }

    private static func applyPbxprojIdentity(
        projectRoot: URL,
        identity: ProjectAppIdentity,
        bundleIdentifier: String?,
        developmentTeam: String?
    ) throws {
        let projURL = try findContainedXcodeProj(projectRoot: projectRoot)
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        var text = try String(contentsOf: pbxPath, encoding: .utf8)

        guard let configIDs = try applicationTargetConfigurationIDs(in: text) else {
            throw ProjectAppIdentityError.noApplicationTarget
        }

        for id in configIDs {
            guard let range = blockRange(forConfigurationID: id, in: text) else {
                throw ProjectAppIdentityError.parseFailure("Missing XCBuildConfiguration \(id).")
            }
            let block = String(text[range])
            let updated = replaceBuildSettings(
                in: block,
                productName: identity.productName,
                displayName: identity.displayName,
                marketingVersion: identity.marketingVersion,
                buildNumber: identity.buildNumber,
                bundleIdentifier: bundleIdentifier,
                developmentTeam: developmentTeam
            )
            text.replaceSubrange(range, with: updated)
        }

        do {
            try text.data(using: .utf8)?.write(to: pbxPath, options: .atomic)
        } catch {
            throw ProjectAppIdentityError.writeFailure(error.localizedDescription)
        }
    }

    private struct InfoPlistIdentity {
        var display: String?
        var shortVersion: String?
        var build: String?
    }

    private static func readInfoPlistIdentity(at url: URL) -> InfoPlistIdentity? {
        guard FileManager.default.fileExists(atPath: url.path),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return nil }
        return InfoPlistIdentity(
            display: dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String,
            shortVersion: dict["CFBundleShortVersionString"] as? String,
            build: dict["CFBundleVersion"] as? String
        )
    }

    private static func resolveInfoPlistURL(projectRoot: URL, infoPlistSetting: String) -> URL? {
        let trimmed = stripQuotes(infoPlistSetting.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }
        var path = trimmed
        path = path.replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
        path = path.replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
    }

    private static func mergeInfoPlist(at url: URL, identity: ProjectAppIdentity) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else { return }
        if !identity.displayName.isEmpty {
            plist["CFBundleDisplayName"] = identity.displayName
        }
        if !identity.marketingVersion.isEmpty {
            plist["CFBundleShortVersionString"] = identity.marketingVersion
        }
        if !identity.buildNumber.isEmpty {
            plist["CFBundleVersion"] = identity.buildNumber
        }
        if !plist.write(toFile: url.path, atomically: true) {
            throw ProjectAppIdentityError.writeFailure("Could not write \(url.lastPathComponent).")
        }
    }

    private static func findContainedXcodeProj(projectRoot: URL) throws -> URL {
        if projectRoot.pathExtension == "xcodeproj" {
            return projectRoot
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let projects = contents.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = projects.first else {
            throw ProjectAppIdentityError.noXcodeProject
        }
        return first
    }

    /// PBXNativeTarget application → XCConfigurationList → XCBuildConfiguration ids.
    private static func applicationTargetConfigurationIDs(in pbx: String) throws -> [String]? {
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

    private static func blockRange(forConfigurationID id: String, in pbx: String) -> Range<String.Index>? {
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

    private static func replaceBuildSettings(
        in block: String,
        productName: String,
        displayName: String,
        marketingVersion: String,
        buildNumber: String,
        bundleIdentifier: String?,
        developmentTeam: String?
    ) -> String {
        var result = block
        result = setOrInsertBuildSetting(result, key: "PRODUCT_NAME", value: pbxEscape(productName))
        result = setOrInsertBuildSetting(result, key: "INFOPLIST_KEY_CFBundleDisplayName", value: pbxEscape(displayName))
        result = setOrInsertBuildSetting(result, key: "MARKETING_VERSION", value: pbxEscape(marketingVersion))
        result = setOrInsertBuildSetting(result, key: "CURRENT_PROJECT_VERSION", value: pbxEscape(buildNumber))
        if let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = setOrInsertBuildSetting(
                result,
                key: "PRODUCT_BUNDLE_IDENTIFIER",
                value: pbxEscape(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        if let developmentTeam, !developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = setOrInsertBuildSetting(
                result,
                key: "DEVELOPMENT_TEAM",
                value: pbxEscape(developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        return result
    }

    private static func hexIDs(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{24}") else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }

    private static func setOrInsertBuildSetting(_ block: String, key: String, value: String) -> String {
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

    private static func pbxEscape(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\"") else {
            return "\"" + trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        if trimmed.contains(" ") || trimmed.contains("$") || trimmed.isEmpty {
            return "\"" + trimmed + "\""
        }
        return trimmed
    }

    private static func stripQuotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            t.removeFirst()
            t.removeLast()
            return t.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return t
    }
}

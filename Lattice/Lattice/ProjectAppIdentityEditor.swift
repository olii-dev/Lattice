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

        var productName = PbxprojEditor.stripQuotes(value(for: "PRODUCT_NAME", in: settings) ?? "")
        var display = PbxprojEditor.stripQuotes(
            value(for: "INFOPLIST_KEY_CFBundleDisplayName", in: settings)
                ?? value(for: "INFOPLIST_KEY_CFBundleName", in: settings)
                ?? ""
        )
        var marketing = PbxprojEditor.stripQuotes(value(for: "MARKETING_VERSION", in: settings) ?? "")
        var buildNum = PbxprojEditor.stripQuotes(value(for: "CURRENT_PROJECT_VERSION", in: settings) ?? "")

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
        let s = PbxprojEditor.stripQuotes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
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

        guard let configIDs = PbxprojEditor.applicationTargetConfigurationIDs(in: text) else {
            throw ProjectAppIdentityError.noApplicationTarget
        }

        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: text) else {
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
        let trimmed = PbxprojEditor.stripQuotes(infoPlistSetting.trimmingCharacters(in: .whitespacesAndNewlines))
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
        result = PbxprojEditor.setOrInsertBuildSetting(result, key: "PRODUCT_NAME", value: PbxprojEditor.pbxEscape(productName))
        result = PbxprojEditor.setOrInsertBuildSetting(result, key: "INFOPLIST_KEY_CFBundleDisplayName", value: PbxprojEditor.pbxEscape(displayName))
        result = PbxprojEditor.setOrInsertBuildSetting(result, key: "MARKETING_VERSION", value: PbxprojEditor.pbxEscape(marketingVersion))
        result = PbxprojEditor.setOrInsertBuildSetting(result, key: "CURRENT_PROJECT_VERSION", value: PbxprojEditor.pbxEscape(buildNumber))
        if let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = PbxprojEditor.setOrInsertBuildSetting(
                result,
                key: "PRODUCT_BUNDLE_IDENTIFIER",
                value: PbxprojEditor.pbxEscape(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        if let developmentTeam, !developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = PbxprojEditor.setOrInsertBuildSetting(
                result,
                key: "DEVELOPMENT_TEAM",
                value: PbxprojEditor.pbxEscape(developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        return result
    }
}

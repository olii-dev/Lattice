import AppKit
import Foundation

enum ProjectTemplatePlatform: String, CaseIterable, Identifiable {
    case iOS
    case macOS
    case watchOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iOS: return "iOS"
        case .macOS: return "macOS"
        case .watchOS: return "watchOS"
        }
    }

    /// Subfolder under `ProjectTemplates` in the app bundle.
    var templatesSubfolder: String {
        switch self {
        case .iOS: return "ios"
        case .macOS: return "macos"
        case .watchOS: return "watchos"
        }
    }
}

enum ProjectTemplateCopierError: LocalizedError {
    case missingTemplatesInBundle
    case templateFolderMissing(String)
    case invalidProductName
    case invalidOrganizationIdentifier
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplatesInBundle:
            return "Project templates are missing from the app bundle."
        case .templateFolderMissing(let name):
            return "Template folder “\(name)” was not found."
        case .invalidProductName:
            return "Enter a product name using letters and numbers."
        case .invalidOrganizationIdentifier:
            return "Enter a reverse-DNS identifier (e.g. com.mycompany)."
        case .copyFailed(let reason):
            return reason
        }
    }
}

enum ProjectTemplateCopier {
    private static let templateTokenName = "LatticeTplApp"
    private static let templateTokenOrg = "com.lattice.template"
    private static let templateTokenBundle = "com.lattice.template.LatticeTplApp"

    static func sanitizedProductName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.filter { $0.isLetter || $0.isNumber }
        guard !compact.isEmpty else { return nil }
        guard compact.first?.isLetter == true else { return nil }
        return compact
    }

    static func normalizedOrgIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        else { return nil }
        return parts.joined(separator: ".")
    }

    static func bundleIdentifier(org: String, product: String) -> String {
        "\(org).\(product)"
    }

    /// Copies a bundled template into `parentDirectory/ProductName/` and returns the new project root (folder containing the `.xcodeproj`).
    static func createProject(
        platform: ProjectTemplatePlatform,
        productName rawProduct: String,
        organizationIdentifier rawOrg: String,
        parentDirectory: URL
    ) throws -> URL {
        guard let product = sanitizedProductName(rawProduct) else {
            throw ProjectTemplateCopierError.invalidProductName
        }
        guard let org = normalizedOrgIdentifier(rawOrg) else {
            throw ProjectTemplateCopierError.invalidOrganizationIdentifier
        }
        let bundleId = bundleIdentifier(org: org, product: product)

        guard let templatesRoot = Bundle.main.url(forResource: "ProjectTemplates", withExtension: nil) else {
            throw ProjectTemplateCopierError.missingTemplatesInBundle
        }
        let srcRoot = templatesRoot.appendingPathComponent(platform.templatesSubfolder, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: srcRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectTemplateCopierError.templateFolderMissing(platform.templatesSubfolder)
        }

        let destRoot = parentDirectory.appendingPathComponent(product, isDirectory: true)
        if FileManager.default.fileExists(atPath: destRoot.path) {
            throw ProjectTemplateCopierError.copyFailed("A folder named “\(product)” already exists in the chosen location.")
        }

        try FileManager.default.copyItem(at: srcRoot, to: destRoot)

        let replacements: [(String, String)] = [
            (templateTokenName, product),
            (templateTokenOrg, org),
            (templateTokenBundle, bundleId),
        ]

        try applyReplacements(in: destRoot, replacements: replacements)
        try renamePaths(containing: templateTokenName, to: product, root: destRoot)

        guard let xcodeproj = findXcodeproj(in: destRoot) else {
            throw ProjectTemplateCopierError.copyFailed("Could not find an .xcodeproj after creating the template.")
        }
        return xcodeproj.deletingLastPathComponent()
    }

    private static func findXcodeproj(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "xcodeproj" { found.append(url) }
        }
        return found.sorted { $0.path.count < $1.path.count }.first
    }

    private static func applyReplacements(in root: URL, replacements: [(String, String)]) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard isFile else { continue }
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { continue }
            guard var text = String(data: data, encoding: .utf8) else { continue }
            var changed = false
            for (from, to) in replacements where text.contains(from) {
                text = text.replacingOccurrences(of: from, with: to)
                changed = true
            }
            if changed {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func renamePaths(containing token: String, to product: String, root: URL) throws {
        var paths: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                paths.append(url)
            }
        }
        paths.sort { $0.path.count > $1.path.count }
        for url in paths where url.lastPathComponent.contains(token) {
            let newName = url.lastPathComponent.replacingOccurrences(of: token, with: product)
            guard newName != url.lastPathComponent else { continue }
            let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.moveItem(at: url, to: dest)
            }
        }
    }
}

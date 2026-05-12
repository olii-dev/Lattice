import AppKit
import SwiftUI

enum ProjectFolderIcon {
    /// Prefer app icon assets from the project; fallback to workspace/project icon; then folder icon.
    static func nsImage(forProjectFolder path: String) -> NSImage {
        let folder = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return NSImage(named: NSImage.folderName) ?? NSImage()
        }
        if let icon = firstProjectAppIcon(in: folder) {
            return icon
        }
        if let proj = firstXcodeProject(in: folder) {
            return NSWorkspace.shared.icon(forFile: proj.path)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    static func firstXcodeProject(in folder: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let projects = entries.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return projects.first
    }

    static func firstProjectAppIcon(in folder: URL) -> NSImage? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var appIconSetURL: URL?
        for case let url as URL in enumerator {
            if url.lastPathComponent == "AppIcon.appiconset" {
                appIconSetURL = url
                break
            }
        }
        guard let iconSet = appIconSetURL else { return nil }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: iconSet,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
        let sorted = pngs.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let r = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return l > r
        }
        guard let best = sorted.first else { return nil }
        return NSImage(contentsOf: best)
    }
}

struct ProjectFolderIconView: View {
    let path: String
    private var image: NSImage { ProjectFolderIcon.nsImage(forProjectFolder: path) }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)
    }
}

import AppKit
import Foundation

enum ProjectAppIconWriterError: LocalizedError {
    case noAppIconSet
    case pngEncodeFailed

    var errorDescription: String? {
        switch self {
        case .noAppIconSet:
            return "Could not find AppIcon.appiconset in this project. Lattice templates include one; add an App Icon set in Xcode for other projects."
        case .pngEncodeFailed:
            return "Could not encode the icon as PNG."
        }
    }
}

private struct AppIconContentsJSON: Decodable {
    struct Image: Decodable {
        var filename: String?
    }
    var images: [Image]
}

/// Writes a 1024×1024 PNG into an existing `AppIcon.appiconset` (Lattice templates ship one).
enum ProjectAppIconWriter {
    /// Locates the first `AppIcon.appiconset` under the project folder.
    static func findAppIconSet(in projectRoot: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "AppIcon.appiconset" {
                return url
            }
        }
        return nil
    }

    /// Rasterizes `image` to PNG data at the given pixel size (square).
    static func pngData(from image: NSImage, pixelSize: Int) -> Data? {
        let w = max(1, pixelSize)
        let h = max(1, pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }

        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
        let src = image.size.width > 0 ? image.size : NSSize(width: w, height: h)
        image.draw(
            in: NSRect(x: 0, y: 0, width: w, height: h),
            from: NSRect(x: 0, y: 0, width: src.width, height: src.height),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func primaryIconFilename(in appIconSet: URL) throws -> String {
        let contentsURL = appIconSet.appendingPathComponent("Contents.json")
        let data = try Data(contentsOf: contentsURL)
        if let decoded = try? JSONDecoder().decode(AppIconContentsJSON.self, from: data),
           let name = decoded.images.compactMap(\.filename).first,
           !name.isEmpty {
            return name
        }
        return "AppIcon.png"
    }

    /// Writes `image` into the project’s App Icon set (replaces the main catalog PNG).
    static func write(image: NSImage, projectRoot: URL) throws {
        guard let set = findAppIconSet(in: projectRoot) else {
            throw ProjectAppIconWriterError.noAppIconSet
        }
        let filename = try primaryIconFilename(in: set)
        guard let png = pngData(from: image, pixelSize: 1024) else {
            throw ProjectAppIconWriterError.pngEncodeFailed
        }
        let dest = set.appendingPathComponent(filename)
        try png.write(to: dest, options: .atomic)
    }
}

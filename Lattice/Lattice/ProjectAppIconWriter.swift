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
    struct GeneratedIconSpec {
        let symbolName: String
        let startColor: NSColor
        let endColor: NSColor
    }

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

    static func generatedSpec(summary: LatticeProjectSummary, projectName: String) -> GeneratedIconSpec {
        let text = [
            summary.appName,
            summary.concept,
            summary.surfacesLine,
            projectName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        let matches: [([String], GeneratedIconSpec)] = [
            (["journal", "note", "diary", "write"], GeneratedIconSpec(symbolName: "book.closed.fill", startColor: NSColor(calibratedRed: 0.82, green: 0.59, blue: 0.33, alpha: 1), endColor: NSColor(calibratedRed: 0.62, green: 0.39, blue: 0.23, alpha: 1))),
            (["task", "todo", "planner", "schedule", "calendar"], GeneratedIconSpec(symbolName: "checklist.checked", startColor: NSColor(calibratedRed: 0.29, green: 0.54, blue: 0.93, alpha: 1), endColor: NSColor(calibratedRed: 0.19, green: 0.35, blue: 0.72, alpha: 1))),
            (["chat", "message", "social", "community"], GeneratedIconSpec(symbolName: "bubble.left.and.bubble.right.fill", startColor: NSColor(calibratedRed: 0.48, green: 0.45, blue: 0.92, alpha: 1), endColor: NSColor(calibratedRed: 0.30, green: 0.28, blue: 0.71, alpha: 1))),
            (["music", "audio", "podcast"], GeneratedIconSpec(symbolName: "music.note", startColor: NSColor(calibratedRed: 0.91, green: 0.29, blue: 0.49, alpha: 1), endColor: NSColor(calibratedRed: 0.69, green: 0.17, blue: 0.34, alpha: 1))),
            (["photo", "camera", "gallery"], GeneratedIconSpec(symbolName: "camera.fill", startColor: NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.28, alpha: 1), endColor: NSColor(calibratedRed: 0.78, green: 0.38, blue: 0.16, alpha: 1))),
            (["health", "fitness", "workout"], GeneratedIconSpec(symbolName: "heart.fill", startColor: NSColor(calibratedRed: 0.95, green: 0.38, blue: 0.46, alpha: 1), endColor: NSColor(calibratedRed: 0.75, green: 0.20, blue: 0.30, alpha: 1))),
            (["finance", "money", "budget", "expense"], GeneratedIconSpec(symbolName: "dollarsign.circle.fill", startColor: NSColor(calibratedRed: 0.24, green: 0.65, blue: 0.43, alpha: 1), endColor: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.29, alpha: 1))),
            (["travel", "trip", "flight", "map"], GeneratedIconSpec(symbolName: "map.fill", startColor: NSColor(calibratedRed: 0.29, green: 0.68, blue: 0.63, alpha: 1), endColor: NSColor(calibratedRed: 0.13, green: 0.43, blue: 0.44, alpha: 1))),
            (["weather", "forecast"], GeneratedIconSpec(symbolName: "cloud.sun.fill", startColor: NSColor(calibratedRed: 0.49, green: 0.64, blue: 0.93, alpha: 1), endColor: NSColor(calibratedRed: 0.31, green: 0.40, blue: 0.73, alpha: 1))),
            (["food", "recipe", "meal"], GeneratedIconSpec(symbolName: "fork.knife", startColor: NSColor(calibratedRed: 0.92, green: 0.51, blue: 0.31, alpha: 1), endColor: NSColor(calibratedRed: 0.72, green: 0.30, blue: 0.18, alpha: 1))),
            (["shop", "store", "cart"], GeneratedIconSpec(symbolName: "bag.fill", startColor: NSColor(calibratedRed: 0.73, green: 0.52, blue: 0.92, alpha: 1), endColor: NSColor(calibratedRed: 0.49, green: 0.31, blue: 0.71, alpha: 1)))
        ]

        for (keywords, spec) in matches where keywords.contains(where: { text.contains($0) }) {
            return spec
        }

        return GeneratedIconSpec(
            symbolName: "square.grid.2x2.fill",
            startColor: NSColor(calibratedRed: 0.42, green: 0.49, blue: 0.65, alpha: 1),
            endColor: NSColor(calibratedRed: 0.25, green: 0.29, blue: 0.42, alpha: 1)
        )
    }

    static func generatedImage(summary: LatticeProjectSummary, projectName: String, size: CGFloat = 1024) -> NSImage? {
        let spec = generatedSpec(summary: summary, projectName: projectName)
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(size: frame.size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rounded = NSBezierPath(roundedRect: frame, xRadius: size * 0.224, yRadius: size * 0.224)
        let gradient = NSGradient(starting: spec.startColor, ending: spec.endColor)
        gradient?.draw(in: rounded, angle: -45)

        let glossRect = NSRect(x: size * 0.08, y: size * 0.56, width: size * 0.84, height: size * 0.28)
        let gloss = NSBezierPath(roundedRect: glossRect, xRadius: size * 0.12, yRadius: size * 0.12)
        NSColor.white.withAlphaComponent(0.10).setFill()
        gloss.fill()

        if let symbol = NSImage(systemSymbolName: spec.symbolName, accessibilityDescription: nil) {
            let pointSize = size * 0.42
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            let symbolImage = symbol.withSymbolConfiguration(config) ?? symbol
            let symbolRect = NSRect(
                x: (size - pointSize) / 2,
                y: (size - pointSize) / 2 - size * 0.01,
                width: pointSize,
                height: pointSize
            )
            NSColor.white.withAlphaComponent(0.96).setFill()
            symbolImage.draw(in: symbolRect)
        }

        return image
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

    static func writeGenerated(summary: LatticeProjectSummary, projectRoot: URL) throws {
        let projectName = projectRoot.deletingPathExtension().lastPathComponent
        guard let image = generatedImage(summary: summary, projectName: projectName) else {
            throw ProjectAppIconWriterError.pngEncodeFailed
        }
        try write(image: image, projectRoot: projectRoot)
    }
}

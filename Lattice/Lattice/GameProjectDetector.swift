import Foundation

/// Recognises whether a project is a game, so the agent can switch into Game Mode.
/// Two independent signals, either is enough:
///  1. an explicit marker file written at new-project time (`.lattice-game`);
///  2. source evidence — the project imports/uses Apple game frameworks.
enum GameProjectDetector {
    static let markerFileName = ".lattice-game"

    struct Signal: Equatable {
        let isGame: Bool
        /// Short engine hint surfaced to the agent, or nil when unclear.
        let engineHint: String?
    }

    /// Framework/scene tokens that mean "this is a game", mapped to a human hint.
    private static let engineTokens: [(hint: String, tokens: [String])] = [
        ("RealityKit / ARKit (3D, AR)", ["import RealityKit", "import ARKit", "ARView", "RealityView", "Entity("]),
        ("GameplayKit (AI, state machines)", ["import GameplayKit", "GKStateMachine", "GKAgent", "GKGraphNode"]),
        ("SpriteKit (2D)", ["import SpriteKit", "SKScene", "SKView", "SpriteView", "SKSpriteNode", "SKAction", "SKPhysicsBody"]),
        ("Metal (custom engine)", ["import MetalKit", "MTKView", "MTLRenderPipeline"]),
    ]

    private static let swiftScanCap = 500
    private static let maxFileBytes = 400_000
    private static let skipDirectories: Set<String> = [
        "DerivedData", "build", ".git", "Pods", "Carthage", ".swiftpm", "Package.resolved",
    ]

    static func detect(projectRoot: URL) -> Signal {
        let marker = projectRoot.appendingPathComponent(markerFileName)
        if FileManager.default.fileExists(atPath: marker.path) {
            return Signal(isGame: true, engineHint: scanEngineHint(projectRoot: projectRoot))
        }
        let hint = scanEngineHint(projectRoot: projectRoot)
        return Signal(isGame: hint != nil, engineHint: hint)
    }

    /// True if any Swift source in the project shows a game framework being used.
    static func looksLikeGame(projectRoot: URL) -> Bool {
        scanEngineHint(projectRoot: projectRoot) != nil
            || FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(markerFileName).path)
    }

    static func writeMarker(projectRoot: URL) {
        let marker = projectRoot.appendingPathComponent(markerFileName)
        try? Data("Lattice game project\n".utf8).write(to: marker, options: .atomic)
    }

    // MARK: - Source scanning

    private static func scanEngineHint(projectRoot: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var scanned = 0
        for case let url as URL in enumerator {
            if scanned >= swiftScanCap { break }
            let components = url.pathComponents
            if components.contains(where: { skipDirectories.contains($0) }) {
                if url.pathExtension == "swift" { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size <= maxFileBytes
            else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for entry in engineTokens {
                if entry.tokens.contains(where: { text.contains($0) }) {
                    return entry.hint
                }
            }
        }
        return nil
    }
}

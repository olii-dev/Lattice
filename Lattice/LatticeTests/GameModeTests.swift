import Testing
import Foundation
@testable import Lattice

@Suite struct GameProjectDetectorTests {

    private static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-game-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func emptyProjectIsNotGame() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!GameProjectDetector.detect(projectRoot: dir).isGame)
    }

    @Test func plainSwiftUIAppIsNotGame() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import SwiftUI
        struct ContentView: View { var body: some View { Text("Hi") } }
        """.write(to: dir.appendingPathComponent("ContentView.swift"), atomically: true, encoding: .utf8)
        #expect(!GameProjectDetector.detect(projectRoot: dir).isGame)
    }

    @Test func spriteKitProjectIsGameWithHint() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import SpriteKit
        class GameScene: SKScene { }
        """.write(to: dir.appendingPathComponent("GameScene.swift"), atomically: true, encoding: .utf8)
        let signal = GameProjectDetector.detect(projectRoot: dir)
        #expect(signal.isGame)
        #expect(signal.engineHint == "SpriteKit (2D)")
    }

    @Test func realityKitProjectDetectedAs3D() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "import RealityKit\nstruct V: View { var body: some View { RealityView { _ in } } }"
            .write(to: dir.appendingPathComponent("V.swift"), atomically: true, encoding: .utf8)
        let signal = GameProjectDetector.detect(projectRoot: dir)
        #expect(signal.isGame)
        #expect(signal.engineHint?.contains("RealityKit") == true)
    }

    @Test func markerFileMakesItAGame() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hi".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        #expect(!GameProjectDetector.detect(projectRoot: dir).isGame)
        GameProjectDetector.writeMarker(projectRoot: dir)
        #expect(GameProjectDetector.detect(projectRoot: dir).isGame)
    }

    @Test func derivedDataIsIgnored() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let build = dir.appendingPathComponent("DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "import SpriteKit\nlet x = SKScene()".write(
            to: build.appendingPathComponent("leak.swift"), atomically: true, encoding: .utf8
        )
        #expect(!GameProjectDetector.detect(projectRoot: dir).isGame)
    }
}

@Suite struct GameModePromptTests {

    private static func context(isGame: Bool, hint: String? = nil) -> ChatContext {
        ChatContext(
            runTarget: nil, projectPath: nil, model: "m", provider: "anthropic",
            zaiUseCodingEndpoint: false, buildInfo: nil, bundleIdentifierOverride: nil,
            developmentTeam: nil, projectSummary: nil, customProvider: nil,
            isGame: isGame, gameEngineHint: hint
        )
    }

    @Test func gamesSectionAddedOnlyForGames() {
        let game = LLMService.latticeSystemPrompt(for: Self.context(isGame: true, hint: "SpriteKit (2D)"))
        let app = LLMService.latticeSystemPrompt(for: Self.context(isGame: false))
        #expect(game.contains("GAME MODE"))
        #expect(game.contains("SpriteKit (2D)"))
        #expect(!app.contains("GAME MODE"))
    }

    @Test func promptNoLongerReferencesPhantomTool() {
        let game = LLMService.latticeSystemPrompt(for: Self.context(isGame: true))
        let app = LLMService.latticeSystemPrompt(for: Self.context(isGame: false))
        #expect(!game.contains("xcodebuildmcp"))
        #expect(!app.contains("xcodebuildmcp"))
        #expect(game.contains("simulator_use"))
    }

    @Test func gamesSectionIncludesFeelAndVerification() {
        let section = LLMService.latticeGamesSection(engineHint: nil)
        #expect(section.contains("state machine"))
        #expect(section.contains("GAME FEEL"))
        #expect(section.contains("screen shake"))
        #expect(section.contains("VERIFY LIKE A PLAYER"))
        #expect(section.contains("No engine detected"))
    }
}

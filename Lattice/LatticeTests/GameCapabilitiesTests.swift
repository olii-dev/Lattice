import Testing
import Foundation
@testable import Lattice

@Suite struct GameCapabilitiesTests {

    // MARK: Game Center (seed-only, detected via seed marker)

    @Test func gameCenterSeedsManagerAndDetects() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        let result = try await CapabilityApplicator.apply(capabilityId: "game_center", to: root, parameters: [:])
        let seedURL = root.appendingPathComponent("LatticeTplApp/GameCenter.swift")
        #expect(FileManager.default.fileExists(atPath: seedURL.path))
        #expect(result.changedFiles.contains(seedURL))
        let text = try String(contentsOf: seedURL, encoding: .utf8)
        #expect(text.contains("GKLocalPlayer"))
        #expect(text.contains("submitScore"))

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("game_center"))
    }

    @Test func gameCenterReapplyIsIdempotentAndRemoveKeepsSeed() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "game_center", to: root, parameters: [:])
        let seedURL = root.appendingPathComponent("LatticeTplApp/GameCenter.swift")
        try "// edited\n".write(to: seedURL, atomically: true, encoding: .utf8)

        let second = try await CapabilityApplicator.apply(capabilityId: "game_center", to: root, parameters: [:])
        #expect(!second.changedFiles.contains(seedURL))
        try "// edited\n".write(to: seedURL, atomically: true, encoding: .utf8) // restore check below

        _ = try await CapabilityApplicator.remove(capabilityId: "game_center", from: root)
        // Removing never deletes user-facing seed files.
        #expect(FileManager.default.fileExists(atPath: seedURL.path))
    }

    // MARK: AR (plist key + seed)

    @Test func arWritesCameraUsageAndSeed() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "ar", to: root,
            parameters: ["CameraUsageDescription": "Place virtual objects in your room."]
        )

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("LatticeTplApp/ARSupport.swift").path))
        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("ar"))
    }

    @Test func arWithoutDescriptionStillCountsActiveViaSeed() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        // No param → the NSCameraUsageDescription key is dropped, but the seed file
        // still marks the capability active (same fallback as other seeded caps).
        _ = try await CapabilityApplicator.apply(capabilityId: "ar", to: root, parameters: [:])
        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("ar"))
    }

    @Test func gameCapabilitiesAreInCatalog() {
        #expect(AppleCapabilityCatalog.capability(id: "game_center") != nil)
        #expect(AppleCapabilityCatalog.capability(id: "ar")?.applicablePlatforms == [.iOS])
    }
}

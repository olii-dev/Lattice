import Testing
import Foundation
@testable import Lattice

@Suite struct DatabaseCapabilityTests {

    // MARK: - SwiftData seed file

    @Test func applySwiftDataCreatesSeedFile() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "swiftdata", to: root, parameters: [:]
        )
        let seedURL = root.appendingPathComponent("LatticeTplApp/SampleData.swift")
        #expect(FileManager.default.fileExists(atPath: seedURL.path))
        #expect(result.changedFiles.contains(seedURL))
        let contents = try String(contentsOf: seedURL, encoding: .utf8)
        #expect(contents.contains("@Model"))
        #expect(contents.contains("final class SampleItem"))
    }

    @Test func applySwiftDataIsIdempotentAndNeverOverwritesUserEdits() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "swiftdata", to: root, parameters: [:]
        )
        let seedURL = root.appendingPathComponent("LatticeTplApp/SampleData.swift")
        try "// my precious edits\n".write(to: seedURL, atomically: true, encoding: .utf8)

        let second = try await CapabilityApplicator.apply(
            capabilityId: "swiftdata", to: root, parameters: [:]
        )
        let contents = try String(contentsOf: seedURL, encoding: .utf8)
        #expect(contents == "// my precious edits\n")
        #expect(!second.changedFiles.contains(seedURL))
    }

    @Test func removeSwiftDataKeepsSeedFile() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "swiftdata", to: root, parameters: [:]
        )
        let seedURL = root.appendingPathComponent("LatticeTplApp/SampleData.swift")
        let removal = try await CapabilityApplicator.remove(capabilityId: "swiftdata", from: root)
        #expect(FileManager.default.fileExists(atPath: seedURL.path))
        #expect(removal.removedKeys.isEmpty)
    }

    @Test func statusCheckerDetectsSwiftDataViaSeedFile() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        var status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(!status.activeCapabilities.contains("swiftdata"))

        _ = try await CapabilityApplicator.apply(
            capabilityId: "swiftdata", to: root, parameters: [:]
        )
        status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("swiftdata"))
    }

    // MARK: - CloudKit sync entitlements

    @Test func applyCloudKitWritesServicesAndMergesBackgroundModes() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        // Apply push first so UIBackgroundModes already exists — CloudKit's
        // remote-notification must merge, not clobber.
        _ = try await CapabilityApplicator.apply(
            capabilityId: "push_notifications",
            to: root,
            parameters: ["APSEnvironment": "development"]
        )
        _ = try await CapabilityApplicator.apply(
            capabilityId: "cloudkit_sync",
            to: root,
            parameters: ["iCloudContainerIdentifiers": ["iCloud.com.example.app"]]
        )

        let entitlementsURL = root
            .appendingPathComponent("LatticeTplApp/LatticeTplApp.entitlements")
        let dict = try #require(NSDictionary(contentsOf: entitlementsURL) as? [String: Any])
        #expect(dict["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(dict["com.apple.developer.icloud-container-identifiers"] as? [String] == ["iCloud.com.example.app"])

        // Plist markers: aps-environment entitlement + merged background modes
        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("push_notifications"))
        #expect(status.activeCapabilities.contains("cloudkit_sync"))
    }

    @Test func applyCloudKitWithoutContainersOmitsContainerEntitlement() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "cloudkit_sync", to: root, parameters: [:]
        )
        let entitlementsURL = root
            .appendingPathComponent("LatticeTplApp/LatticeTplApp.entitlements")
        let dict = try #require(NSDictionary(contentsOf: entitlementsURL) as? [String: Any])
        #expect(dict["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(dict["com.apple.developer.icloud-container-identifiers"] == nil)
    }

    @Test func removeCloudKitStripsIcloudKeys() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "cloudkit_sync",
            to: root,
            parameters: ["iCloudContainerIdentifiers": ["iCloud.com.example.app"]]
        )
        let removal = try await CapabilityApplicator.remove(capabilityId: "cloudkit_sync", from: root)
        #expect(removal.removedKeys.contains("com.apple.developer.icloud-services"))
        #expect(removal.removedKeys.contains("com.apple.developer.icloud-container-identifiers"))

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(!status.activeCapabilities.contains("cloudkit_sync"))
    }
}

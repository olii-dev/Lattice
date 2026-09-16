import Testing
import Foundation
@testable import Lattice

@Suite struct HealthKitAppIntentsCapabilityTests {

    // MARK: - HealthKit

    @Test func applyHealthKitWritesEntitlementAndUsageDescriptions() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "healthkit",
            to: root,
            parameters: [
                "HealthShareUsageDescription": "Shows your workout progress.",
                "HealthUpdateUsageDescription": "Saves workouts you log.",
            ]
        )

        let entitlementsURL = root.appendingPathComponent("LatticeTplApp/LatticeTplApp.entitlements")
        let ent = try #require(NSDictionary(contentsOf: entitlementsURL) as? [String: Any])
        #expect(ent["com.apple.developer.healthkit"] as? Bool == true)

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("healthkit"))
    }

    @Test func removeHealthKitStripsEntitlement() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "healthkit",
            to: root,
            parameters: [
                "HealthShareUsageDescription": "Reads workouts.",
                "HealthUpdateUsageDescription": "Writes workouts.",
            ]
        )
        let removal = try await CapabilityApplicator.remove(capabilityId: "healthkit", from: root)
        #expect(removal.removedKeys.contains("com.apple.developer.healthkit"))

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(!status.activeCapabilities.contains("healthkit"))
    }

    @Test func healthkitIsIOSTargeted() {
        let cap = AppleCapabilityCatalog.capability(id: "healthkit")!
        #expect(cap.applicablePlatforms == [.iOS])
    }

    // MARK: - App Intents

    @Test func applyAppIntentsSeedsIntentFile() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "app_intents", to: root, parameters: [:]
        )
        let seedURL = root.appendingPathComponent("LatticeTplApp/SampleIntents.swift")
        #expect(FileManager.default.fileExists(atPath: seedURL.path))
        #expect(result.changedFiles.contains(seedURL))
        let contents = try String(contentsOf: seedURL, encoding: .utf8)
        #expect(contents.contains("AppIntent"))
        #expect(contents.contains("IntentDescription"))
    }

    @Test func statusCheckerDetectsAppIntentsViaSeed() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        var status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(!status.activeCapabilities.contains("app_intents"))

        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_intents", to: root, parameters: [:]
        )
        status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("app_intents"))
    }
}

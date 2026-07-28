import Testing
import Foundation
@testable import Lattice

@Suite struct CapabilityStatusCheckerTests {
    @Test func noCapabilitiesActiveByDefault() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        #expect(status.activeCapabilities.isEmpty)
    }

    @Test func detectsAppGroupsAfterApply() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }
        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        #expect(status.activeCapabilities.contains("app_groups"))
    }

    @Test func detectsMultipleCapabilities() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }
        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        _ = try await CapabilityApplicator.apply(
            capabilityId: "background_modes", to: fixtureRoot,
            parameters: ["UIBackgroundModes": ["audio"]]
        )
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        #expect(status.activeCapabilities.contains("app_groups"))
        #expect(status.activeCapabilities.contains("background_modes"))
    }

    @Test func storekitIsUndetectable() async throws {
        // StoreKit has no entitlement/plist markers — it never appears in activeCapabilities.
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }
        _ = try await CapabilityApplicator.apply(
            capabilityId: "storekit", to: fixtureRoot, parameters: [:]
        )
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        #expect(!status.activeCapabilities.contains("storekit"))
    }

    @Test func removeClearsStatus() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }
        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        _ = try await CapabilityApplicator.remove(capabilityId: "app_groups", from: fixtureRoot)
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        #expect(!status.activeCapabilities.contains("app_groups"))
    }
}

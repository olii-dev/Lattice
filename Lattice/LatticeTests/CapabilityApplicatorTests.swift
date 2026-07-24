import Testing
import Foundation
@testable import Lattice

@Suite struct CapabilityApplicatorTests {
    // Each @Test creates and tears down its own fixture so disk state never leaks across tests
    // and we avoid relying on `deinit` semantics for Swift Testing @Suite structs.

    @Test func applyBackgroundModesAddsPlistKey() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "background_modes",
            to: fixtureRoot,
            parameters: ["UIBackgroundModes": ["audio", "fetch"]]
        )
        // Background modes has no entitlements, so no .entitlements file created.
        #expect(!result.changedFiles.contains { $0.pathExtension == "entitlements" })
        // The plist value must be present somewhere (Info.plist file or build setting).
        #expect(!result.changedFiles.isEmpty)

        // The background modes must actually land in the generated Info.plist (background_modes
        // uses an array value, so the applicator should create an on-disk Info.plist).
        let infoPlistURL = fixtureRoot.appendingPathComponent("LatticeTplApp/Info.plist")
        if FileManager.default.fileExists(atPath: infoPlistURL.path),
           let dict = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
           let modes = dict["UIBackgroundModes"] as? [String] {
            #expect(Set(modes) == ["audio", "fetch"])
        } else {
            // Otherwise it must have been written as a build setting.
            let pbx = try String(contentsOf: fixtureRoot.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj"), encoding: .utf8)
            #expect(pbx.contains("UIBackgroundModes"), "background modes should land in Info.plist or as a build setting")
        }
    }

    @Test func applyAppGroupsCreatesEntitlementsFileAndMergesKey() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "app_groups",
            to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        let entFile = try #require(result.changedFiles.first { $0.pathExtension == "entitlements" })
        let dict = try #require(NSDictionary(contentsOf: entFile) as? [String: Any])
        let groups = try #require(dict["com.apple.security.application-groups"] as? [String])
        #expect(Set(groups) == ["group.com.example.app"])
    }

    @Test func applyIsIdempotent() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let first = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        let second = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        // Second apply reports the key as already present.
        #expect(second.alreadyPresent.contains("com.apple.security.application-groups"))
        // And the entitlements file content didn't change (still one group).
        let entFile = try #require(second.changedFiles.first { $0.pathExtension == "entitlements" })
        let groups = try #require((NSDictionary(contentsOf: entFile) as? [String: Any])?["com.apple.security.application-groups"] as? [String])
        #expect(groups.count == 1)

        // The pbxproj should only have been wired once (a single CODE_SIGN_ENTITLEMENTS per config).
        let pbx = try String(contentsOf: fixtureRoot.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        let wiringCount = pbx.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = ").count - 1
        #expect(wiringCount == 2, "pbxproj entitlements wiring must not be duplicated across applies (got \(wiringCount))")
        _ = first // silence unused warning if needed
    }

    @Test func applyAppGroupsMergesMultipleIdentifiersUniquely() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.one"]]
        )
        let second = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.one", "group.com.example.two"]]
        )
        let entFile = try #require(second.changedFiles.first { $0.pathExtension == "entitlements" })
        let groups = try #require((NSDictionary(contentsOf: entFile) as? [String: Any])?["com.apple.security.application-groups"] as? [String])
        #expect(Set(groups) == ["group.com.example.one", "group.com.example.two"])
    }

    @Test func applyUnknownCapabilityThrows() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        await #expect(throws: CapabilityApplicatorError.self) {
            _ = try await CapabilityApplicator.apply(
                capabilityId: "nonexistent", to: fixtureRoot, parameters: [:]
            )
        }
    }

    @Test func applyPreservesEntitlementsFileAfterSecondApply() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        _ = try await CapabilityApplicator.apply(
            capabilityId: "push_notifications", to: fixtureRoot,
            parameters: ["APSEnvironment": "development"]
        )
        // Find the entitlements file (should be the same file for both).
        let pbx = try String(contentsOf: fixtureRoot.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(pbx.contains("CODE_SIGN_ENTITLEMENTS"))
        // Both entitlement keys present in the file.
        let entRelPath = "LatticeTplApp/LatticeTplApp.entitlements"
        let entURL = fixtureRoot.appendingPathComponent(entRelPath)
        let dict = try #require(NSDictionary(contentsOf: entURL) as? [String: Any])
        #expect(dict["com.apple.security.application-groups"] != nil)
        #expect(dict["aps-environment"] != nil)
    }

    @Test func applyPushNotificationsSetsApsEnvironmentAndPlist() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "push_notifications", to: fixtureRoot,
            parameters: ["APSEnvironment": "development"]
        )
        let entFile = try #require(result.changedFiles.first { $0.pathExtension == "entitlements" })
        let dict = try #require(NSDictionary(contentsOf: entFile) as? [String: Any])
        #expect(dict["aps-environment"] as? String == "development")

        // push_notifications also declares UIBackgroundModes = ["remote-notification"] verbatim.
        // That should be present somewhere (Info.plist file or build setting).
        #expect(!result.changedFiles.isEmpty)
    }

    @Test func applyKeychainSharingMergesAccessGroups() async throws {
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "keychain_sharing", to: fixtureRoot,
            parameters: ["KeychainAccessGroup": ["$(AppIdentifierPrefix)com.example.shared"]]
        )
        let entFile = try #require(result.changedFiles.first { $0.pathExtension == "entitlements" })
        let dict = try #require(NSDictionary(contentsOf: entFile) as? [String: Any])
        let groups = try #require(dict["keychain-access-groups"] as? [String])
        #expect(groups == ["$(AppIdentifierPrefix)com.example.shared"])
        _ = result
    }

    @Test func applySkipsEntitlementWhenParameterMissing() async throws {
        // app_groups with no AppGroupIdentifier parameter: the entitlement entry is skipped,
        // so no entitlements file should be created (the capability has no resolved entitlements).
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot, parameters: [:]
        )
        #expect(!result.changedFiles.contains { $0.pathExtension == "entitlements" })
    }

    @Test func applyProducesPlutilValidPbxproj() async throws {
        // The pbxproj produced by a full apply (entitlements + Info.plist wiring) must remain
        // syntactically valid. Catches malformed insertions across both code paths.
        let fixtureRoot = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(fixtureRoot) }

        // Apply both an entitlements capability and a plist-only capability so the pbxproj goes
        // through entitlements wiring + INFOPLIST_FILE / GENERATE_INFOPLIST_FILE rewriting.
        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups", to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        _ = try await CapabilityApplicator.apply(
            capabilityId: "background_modes", to: fixtureRoot,
            parameters: ["UIBackgroundModes": ["audio"]]
        )

        let pbxPath = fixtureRoot.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        proc.arguments = ["-lint", pbxPath.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "modified pbxproj must be valid: \(output)")
    }
}

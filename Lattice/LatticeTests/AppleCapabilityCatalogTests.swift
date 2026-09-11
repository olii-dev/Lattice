import Testing
@testable import Lattice

@Suite struct AppleCapabilityCatalogTests {
    @Test func catalogHasNineCapabilities() {
        #expect(AppleCapabilityCatalog.all.count == 9)
    }

    @Test func swiftdataCapabilityHasSeedFileAndNoEntitlements() {
        let cap = AppleCapabilityCatalog.capability(id: "swiftdata")!
        #expect(cap.entitlements.isEmpty)
        #expect(cap.infoPlistKeys.isEmpty)
        #expect(cap.seedFiles.count == 1)
        #expect(cap.seedFiles[0].relativePath == "$(AppName)/SampleData.swift")
        #expect(cap.seedFiles[0].contents.contains("@Model"))
        #expect(cap.seedFiles[0].contents.contains("import SwiftData"))
    }

    @Test func cloudkitSyncDeclaresIcloudEntitlements() {
        let cap = AppleCapabilityCatalog.capability(id: "cloudkit_sync")!
        #expect(cap.entitlements.contains { $0.key == "com.apple.developer.icloud-services" })
        #expect(cap.entitlements.contains { $0.key == "com.apple.developer.icloud-container-identifiers" })
        #expect(cap.infoPlistKeys.contains { $0.key == "UIBackgroundModes" })
        #expect(cap.provisioningNotes != nil)
    }

    @Test func capabilityIDsAreUnique() {
        let ids = AppleCapabilityCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyCapabilityHasDisplayNameSummaryAndPlatform() {
        for cap in AppleCapabilityCatalog.all {
            #expect(!cap.displayName.isEmpty, "\(cap.id) missing displayName")
            #expect(!cap.summary.isEmpty, "\(cap.id) missing summary")
            #expect(!cap.applicablePlatforms.isEmpty, "\(cap.id) has no platforms")
        }
    }

    @Test func lookupByID() {
        let cap = AppleCapabilityCatalog.capability(id: "app_groups")
        #expect(cap != nil)
        #expect(cap?.displayName == "App Groups")
    }

    @Test func lookupUnknownIDReturnsNil() {
        #expect(AppleCapabilityCatalog.capability(id: "nonexistent") == nil)
    }

    @Test func appGroupsDeclaresEntitlementKey() {
        let cap = AppleCapabilityCatalog.capability(id: "app_groups")!
        #expect(cap.entitlements.contains { $0.key == "com.apple.security.application-groups" })
    }

    @Test func pushNotificationsDeclaresApsEnvironmentAndBackgroundModes() {
        let cap = AppleCapabilityCatalog.capability(id: "push_notifications")!
        #expect(cap.entitlements.contains { $0.key == "aps-environment" })
        #expect(cap.infoPlistKeys.contains { $0.key == "UIBackgroundModes" })
    }

    @Test func pushNotificationsDeclaresUserNotificationsFramework() {
        let cap = AppleCapabilityCatalog.capability(id: "push_notifications")!
        #expect(cap.frameworks.contains("UserNotifications.framework"))
    }

    @Test func storekitHasNoEntitlements() {
        let cap = AppleCapabilityCatalog.capability(id: "storekit")!
        #expect(cap.entitlements.isEmpty)
    }

    @Test func backgroundModesHasNoEntitlementsOnlyPlist() {
        let cap = AppleCapabilityCatalog.capability(id: "background_modes")!
        #expect(cap.entitlements.isEmpty)
        #expect(cap.infoPlistKeys.contains { $0.key == "UIBackgroundModes" })
    }

    @Test func capabilitiesWithProvisioningNeedsHaveNotes() {
        for id in ["app_groups", "push_notifications", "keychain_sharing"] {
            let cap = AppleCapabilityCatalog.capability(id: id)!
            #expect(cap.provisioningNotes != nil, "\(id) should have provisioning notes")
        }
    }
}

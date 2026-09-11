import Testing
import Foundation
@testable import Lattice

@Suite struct LiveActivitiesCapabilityTests {

    @Test func catalogHasElevenCapabilities() {
        #expect(AppleCapabilityCatalog.all.count == 11)
    }

    /// Fresh project, no Widgets capability: live_activities creates the extension
    /// target, the widget bundle, the activity file, and the plist flag.
    @Test func freshPathCreatesExtensionWithActivity() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(
            capabilityId: "live_activities", to: root, parameters: [:]
        )

        let folder = root.appendingPathComponent("LatticeTplAppWidgets")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("LatticeTplAppWidgetsBundle.swift").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("LatticeTplAppLiveActivity.swift").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Info.plist").path))

        let pbx = try String(contentsOf: root.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(pbx.contains("com.apple.product-type.app-extension"))
        // The activity file must be registered in the extension's Sources phase.
        #expect(pbx.contains("path = LatticeTplAppLiveActivity.swift;"))
        #expect(pbx.contains("LatticeTplAppLiveActivity.swift in Sources"))

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("live_activities"))
    }

    /// Widgets applied first: live_activities reuses the extension and only adds the
    /// activity file + plist flag.
    @Test func widgetsThenLiveActivitiesReusesExtension() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "widgets", to: root, parameters: [:])
        let pbxURL = root.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj")
        let afterWidgets = try String(contentsOf: pbxURL, encoding: .utf8)

        _ = try await CapabilityApplicator.apply(capabilityId: "live_activities", to: root, parameters: [:])
        let afterLA = try String(contentsOf: pbxURL, encoding: .utf8)

        // Only one extension target should exist.
        let extCount = afterLA.components(separatedBy: "productType = \"com.apple.product-type.app-extension\";").count - 1
        #expect(extCount == 1, "expected exactly one extension target, got \(extCount)")
        #expect(afterLA.contains("path = LatticeTplAppLiveActivity.swift;"))
        #expect(afterLA.contains("LatticeTplAppLiveActivity.swift in Sources"))
        // Bundle seed from widgets must be untouched.
        #expect(afterLA.contains("path = LatticeTplAppWidgetsBundle.swift;"))

        // App Info.plist gains NSSupportsLiveActivities.
        let infoPlistURL = root.appendingPathComponent("LatticeTplApp/Info.plist")
        if FileManager.default.fileExists(atPath: infoPlistURL.path),
           let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
            #expect(plist["NSSupportsLiveActivities"] as? Bool == true)
        }
    }

    @Test func reapplyingLiveActivitiesIsIdempotent() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "live_activities", to: root, parameters: [:])
        let pbxURL = root.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj")
        let before = try String(contentsOf: pbxURL, encoding: .utf8)

        let second = try await CapabilityApplicator.apply(capabilityId: "live_activities", to: root, parameters: [:])
        let after = try String(contentsOf: pbxURL, encoding: .utf8)
        if before != after {
            // Dump for diagnosis, then fail.
            try? before.write(to: URL(fileURLWithPath: "/tmp/lattice-idem-before.txt"), atomically: true, encoding: .utf8)
            try? after.write(to: URL(fileURLWithPath: "/tmp/lattice-idem-after.txt"), atomically: true, encoding: .utf8)
        }
        #expect(before == after)
        #expect(!second.changedFiles.contains(pbxURL))
    }

    /// Full integration: Xcode must accept the project after the live-activities path.
    @Test func xcodebuildListParsesLiveActivitiesProject() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "live_activities", to: root, parameters: [:])
        let projectURL = root.appendingPathComponent("LatticeTplApp.xcodeproj")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-list", "-project", projectURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = SimulatorBuildRunner.subprocessEnvironment
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "xcodebuild -list failed:\n\(text.prefix(1500))")
        #expect(text.contains("LatticeTplAppWidgets"))
    }
}

import Testing
import Foundation
@testable import Lattice

@Suite struct WidgetCapabilityTests {

    @Test func catalogHasElevenCapabilities() {
        #expect(AppleCapabilityCatalog.all.count == 13)
    }

    @Test func applyWidgetsCreatesSeedFilesAndExtensionTarget() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        let result = try await CapabilityApplicator.apply(
            capabilityId: "widgets", to: root, parameters: [:]
        )

        let folder = root.appendingPathComponent("LatticeTplAppWidgets")
        let swiftURL = folder.appendingPathComponent("LatticeTplAppWidgetsBundle.swift")
        let plistURL = folder.appendingPathComponent("Info.plist")
        #expect(FileManager.default.fileExists(atPath: swiftURL.path))
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(result.changedFiles.contains(swiftURL))

        let swiftSource = try String(contentsOf: swiftURL, encoding: .utf8)
        #expect(swiftSource.contains("WidgetBundle"))
        #expect(swiftSource.contains("StaticConfiguration"))

        // The project file must still be a valid plist and parse in Xcode's toolchain.
        let pbxURL = root.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj")
        let pbxText = try String(contentsOf: pbxURL, encoding: .utf8)
        #expect(pbxText.contains("com.apple.product-type.app-extension"))
        #expect(pbxText.contains("LatticeTplAppWidgets"))
        #expect(pbxText.contains("Embed Foundation Extensions"))
        #expect(pbxText.contains("PBXContainerItemProxy"))
        #expect(pbxText.contains("PBXTargetDependency"))

        let status = try await CapabilityStatusChecker.check(projectRoot: root)
        #expect(status.activeCapabilities.contains("widgets"))
    }

    @Test func applyingWidgetsTwiceIsIdempotent() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "widgets", to: root, parameters: [:])
        let pbxURL = root.appendingPathComponent("LatticeTplApp.xcodeproj/project.pbxproj")
        let before = try String(contentsOf: pbxURL, encoding: .utf8)

        let second = try await CapabilityApplicator.apply(capabilityId: "widgets", to: root, parameters: [:])
        let after = try String(contentsOf: pbxURL, encoding: .utf8)
        #expect(before == after)
        #expect(!second.changedFiles.contains(pbxURL))
    }

    /// Full integration check: Xcode's own toolchain must accept the mutated project.
    @Test func xcodebuildListParsesWidgetProject() async throws {
        let root = try MinimalProjectFixture.make()
        defer { MinimalProjectFixture.tearDown(root) }

        _ = try await CapabilityApplicator.apply(capabilityId: "widgets", to: root, parameters: [:])
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
        #expect(text.contains("LatticeTplAppWidgets"), "extension target missing from scheme list")
    }
}

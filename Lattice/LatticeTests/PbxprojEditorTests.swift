import Foundation
import Testing
@testable import Lattice

@Suite struct PbxprojEditorTests {
    private let pbx = PbxprojFixtures.iosTemplate

    @Test func applicationTargetConfigurationIDs() throws {
        let ids = PbxprojEditor.applicationTargetConfigurationIDs(in: pbx)
        let unwrapped = try #require(ids)
        #expect(Set(unwrapped) == ["A100000A0000000000000003", "A100000A0000000000000004"])
    }

    @Test func setOrInsertBuildSettingReplacesExisting() throws {
        let block = try block(forConfig: "A100000A0000000000000003")
        let updated = PbxprojEditor.setOrInsertBuildSetting(block, key: "MARKETING_VERSION", value: "2.0")
        #expect(updated.contains("MARKETING_VERSION = 2.0;"))
        #expect(!updated.contains("MARKETING_VERSION = 1.0;"))
    }

    @Test func setOrInsertBuildSettingInsertsNew() throws {
        let block = try block(forConfig: "A100000A0000000000000003")
        let updated = PbxprojEditor.setOrInsertBuildSetting(
            block,
            key: "CODE_SIGN_ENTITLEMENTS",
            value: #""LatticeTplApp/LatticeTplApp.entitlements""#
        )
        #expect(updated.contains("CODE_SIGN_ENTITLEMENTS = \"LatticeTplApp/LatticeTplApp.entitlements\";"))
        let count = updated.components(separatedBy: "CODE_SIGN_ENTITLEMENTS").count - 1
        #expect(count == 1)
    }

    @Test func hexIDsExtractsIDs() {
        let ids = PbxprojEditor.hexIDs(in: "foo A10000010000000000000001 bar B20000020000000000000002")
        #expect(ids == ["A10000010000000000000001", "B20000020000000000000002"])
    }

    @Test func pbxEscapePlainToken() {
        #expect(PbxprojEditor.pbxEscape("hello") == "hello")
    }

    @Test func pbxEscapeWithSpace() {
        #expect(PbxprojEditor.pbxEscape("my app") == "\"my app\"")
    }

    @Test func pbxEscapeWithDollarSign() {
        #expect(PbxprojEditor.pbxEscape("$(SRCROOT)") == "\"$(SRCROOT)\"")
    }

    @Test func pbxEscapeEmptyString() {
        #expect(PbxprojEditor.pbxEscape("") == "\"\"")
    }

    @Test func pbxEscapeWithDoubleQuote() {
        // Contains a literal `"`: escapes backslashes first, then quotes, then wraps in quotes.
        #expect(PbxprojEditor.pbxEscape("say \"hi\"") == "\"say \\\"hi\\\"\"")
    }

    @Test func pbxEscapeWithBackslashAndQuote() {
        // Backslash must be escaped to `\\` before the quote is escaped to `\"`.
        #expect(PbxprojEditor.pbxEscape("a\\b\"c") == "\"a\\\\b\\\"c\"")
    }

    @Test func stripQuotesUnquoted() {
        #expect(PbxprojEditor.stripQuotes("hello") == "hello")
    }

    @Test func stripQuotesQuoted() {
        #expect(PbxprojEditor.stripQuotes("\"hello\"") == "hello")
    }

    @Test func stripQuotesQuotedWithEscapedInternalQuote() {
        #expect(PbxprojEditor.stripQuotes("\"say \\\"hi\\\"\"") == "say \"hi\"")
    }

    @Test func stripQuotesTrimsWhitespaceAroundQuotes() {
        #expect(PbxprojEditor.stripQuotes("  \"hi\"  ") == "hi")
    }

    @Test func ensureEntitlementsAddsAllWiring() throws {
        let result = try PbxprojEditor.ensureEntitlementsFileReference(
            in: PbxprojFixtures.iosTemplate,
            relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
        )
        #expect(result.wasModified)
        // PBXFileReference (entitlements type) present.
        #expect(result.modifiedPbx.contains("lastKnownFileType = text.plist.entitlements; path = LatticeTplApp.entitlements;"))
        // PBXBuildFile with "in Resources" present
        #expect(result.modifiedPbx.contains("in Resources"))
        // CODE_SIGN_ENTITLEMENTS set on both configs
        let count = result.modifiedPbx.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = ").count - 1
        #expect(count == 2)
    }

    @Test func ensureEntitlementsIsIdempotent() throws {
        let first = try PbxprojEditor.ensureEntitlementsFileReference(
            in: PbxprojFixtures.iosTemplate,
            relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
        )
        #expect(first.wasModified)
        let second = try PbxprojEditor.ensureEntitlementsFileReference(
            in: first.modifiedPbx,
            relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
        )
        #expect(!second.wasModified)
    }

    @Test func ensureEntitlementsGeneratedIDsAreUniqueAnd24Hex() throws {
        let result = try PbxprojEditor.ensureEntitlementsFileReference(
            in: PbxprojFixtures.iosTemplate,
            relativePath: "App.entitlements"
        )
        let fileRefID = try #require(result.fileReferenceID)
        let buildFileID = try #require(result.buildFileID)
        // 24-char uppercase hex
        #expect(fileRefID.count == 24)
        #expect(fileRefID.allSatisfy { "0123456789ABCDEF".contains($0) })
        #expect(buildFileID.count == 24)
        #expect(fileRefID != buildFileID)
        // Must not collide with existing template IDs (all start with A1)
        #expect(!PbxprojFixtures.iosTemplate.contains(fileRefID))
        #expect(!PbxprojFixtures.iosTemplate.contains(buildFileID))
    }

    @Test func ensureEntitlementsProducesValidPlist() throws {
        // plutil -lint confirms the modified pbxproj is syntactically valid.
        let result = try PbxprojEditor.ensureEntitlementsFileReference(
            in: PbxprojFixtures.iosTemplate,
            relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).pbxproj")
        try result.modifiedPbx.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        proc.arguments = ["-lint", tmp.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "modified pbxproj must be valid: \(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
    }

    @Test func blockRangeSpansWholeConfigBlock() throws {
        let block = try block(forConfig: "A100000A0000000000000003")
        #expect(block.contains("A100000A0000000000000003 /* Debug */"))
        #expect(block.hasSuffix("}"))
        #expect(block.contains("buildSettings = {"))
        #expect(block.contains("name = Debug;"))
    }

    /// Helper that extracts the config block text, failing the test if the id isn't found.
    private func block(forConfig id: String) throws -> String {
        guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else {
            throw TestError("Missing config block for \(id)")
        }
        return String(pbx[range])
    }

    private struct TestError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

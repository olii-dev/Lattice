import Foundation
import Testing
@testable import Lattice

@Suite struct PbxprojEditorTests {
    private let pbx = PbxprojFixtures.iosTemplate

    @Test func applicationTargetConfigurationIDs() throws {
        let ids = try PbxprojEditor.applicationTargetConfigurationIDs(in: pbx)
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

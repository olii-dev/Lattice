# Apple Capability Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Lattice's hand-written entitlements editing with a structured, idempotent capability engine — catalog, applicator, tools, and UI.

**Architecture:** A pure-data `AppleCapabilityCatalog` is the single source of truth. A `CapabilityApplicator` applies/removes capabilities by editing entitlements, Info.plist, and pbxproj via a shared `PbxprojEditor` (extracted from `ProjectAppIdentityEditor`). An `add_capability`/`remove_capability` tool and a `CapabilitySettingsView` both call the same applicator.

**Tech Stack:** Swift, SwiftUI, Foundation (`PropertyListSerialization`, `Process`), XCTest. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-07-24-apple-capability-engine-design.md`

**Key context for the implementer:**
- The iOS project template's pbxproj uses fixed, predictable 24-hex IDs (`A100000X0000000000000YYY`) and a clear section structure. The app target's Resources build phase is `A100000B0000000000000001`. This is the reference fixture.
- `ProjectAppIdentityEditor.swift` already contains working regex-based pbxproj helpers (`applicationTargetConfigurationIDs`, `blockRange(forConfigurationID:)`, `setOrInsertBuildSetting`, `hexIDs`, `pbxEscape`, `stripQuotes`). Task 1 extracts these into a shared module.
- `ToolExecutor` is stateless. The project root is NOT available inside it today — it resolves bash's cwd from `FileManager.default.currentDirectoryPath`. The capability tools will accept an explicit `project_path` argument and the call site in `ContentView.swift:1256` will pass `scopedProjectPath`.
- The LLM system prompt's capability guidance is at `LLMService.swift:749-753`.
- The App Identity editor UI lives in `ContentView.swift:6604-6608` (header) with the Signing section immediately after at `6610+`.

---

## File Structure

**New files** (all under `Lattice/Lattice/`):
- `PbxprojEditor.swift` — shared pbxproj-mutation helpers (extracted from `ProjectAppIdentityEditor`)
- `AppleCapabilityCatalog.swift` — pure data: the capability catalog + supporting types
- `CapabilityApplicator.swift` — apply/remove logic + result types + errors
- `CapabilityStatusChecker.swift` — read-only scan of project state
- `CapabilitySettingsView.swift` — SwiftUI toggle UI

**Test files** (new XCTest target):
- `LatticeTests/PbxprojEditorTests.swift`
- `LatticeTests/AppleCapabilityCatalogTests.swift`
- `LatticeTests/CapabilityApplicatorTests.swift`
- `LatticeTests/CapabilityStatusCheckerTests.swift`
- `LatticeTests/Fixtures/` — minimal pbxproj + entitlements fixtures copied from the iOS template

**Modified files:**
- `ProjectAppIdentityEditor.swift` — delegate to shared `PbxprojEditor`
- `ToolExecutor.swift` — add `add_capability` / `remove_capability` cases
- `LLMService.swift` — rewrite capability prompt lines; add tool definitions
- `ContentView.swift` — pass project root to executor; add `CapabilitySettingsView` Section
- `Lattice.xcodeproj/project.pbxproj` — register new files + test target (via Xcode)

---

## Task 0: Create the test target and a failing sanity test

**Why first:** Every subsequent task uses TDD. We need a test target that builds before any feature code exists.

**Files:**
- Create: `Lattice/LatticeTests/SanityTest.swift`
- Modify: `Lattice/Lattice.xcodeproj/project.pbxproj` (add test target via Xcode)

- [ ] **Step 1: Add a unit testing bundle target in Xcode**

Open `Lattice/Lattice.xcodeproj` in Xcode. File → New → Target… → **Unit Testing Bundle**. Name it `LatticeTests`. Set the host application to `Lattice`. Set the testing system to `XCTest` (not Swift Testing) for compatibility. Ensure "Embed in: Lattice". Save.

- [ ] **Step 2: Verify the test target builds and runs**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED, test target runs (default test passes or "no tests").

- [ ] **Step 3: Write a failing sanity test**

Create `Lattice/LatticeTests/SanityTest.swift`:

```swift
import XCTest
final class SanityTest: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS' -only-testing:LatticeTests/SanityTest`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Lattice/LatticeTests/SanityTest.swift Lattice/Lattice.xcodeproj/project.pbxproj
git commit -m "Add LatticeTests target with sanity test"
```

---

## Task 1: Extract shared `PbxprojEditor` from `ProjectAppIdentityEditor`

**Why:** The catalog and applicator need the same pbxproj helpers that `ProjectAppIdentityEditor` already has. Extracting first avoids divergence.

**Files:**
- Create: `Lattice/Lattice/PbxprojEditor.swift`
- Create: `Lattice/LatticeTests/PbxprojEditorTests.swift`
- Modify: `Lattice/Lattice/ProjectAppIdentityEditor.swift`

- [ ] **Step 1: Add a test fixture**

Create `Lattice/LatticeTests/Fixtures/TemplatePbxproj.swift` — a string constant holding a copy of the iOS template's pbxproj (from `ProjectTemplates/ios/LatticeTplApp.xcodeproj/project.pbxproj`). This is the canonical fixture for pbxproj tests.

```swift
import Foundation

/// Verbatim copy of ProjectTemplates/ios/LatticeTplApp.xcodeproj/project.pbxproj.
/// Used as the fixture for PbxprojEditor tests. Update if the template changes.
enum PbxprojFixtures {
    static let iosTemplate = #"""
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A10000010000000000000001 /* LatticeTplAppApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000020000000000000001 /* LatticeTplAppApp.swift */; };
		A10000010000000000000002 /* ContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000020000000000000002 /* ContentView.swift */; };
		A10000010000000000000003 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = A10000020000000000000003 /* Assets.xcassets */; };
/* End PBXBuildFile section */
"""# // ... (full template continues — paste the complete file)
}
```

Paste the complete template content. Note: keep this as a raw string literal so tests don't depend on the file system.

- [ ] **Step 2: Write failing tests for the extracted helpers**

Create `Lattice/LatticeTests/PbxprojEditorTests.swift`:

```swift
import XCTest
@testable import Lattice

final class PbxprojEditorTests: XCTestCase {
    private let pbx = PbxprojFixtures.iosTemplate

    func testApplicationTargetConfigurationIDs() throws {
        let ids = try PbxprojEditor.applicationTargetConfigurationIDs(in: pbx)
        XCTAssertEqual(Set(ids), ["A100000A0000000000000003", "A100000A0000000000000004"])
    }

    func testSetOrInsertBuildSettingReplacesExisting() throws {
        let block = try PbxprojEditor.blockRange(forConfigurationID: "A100000A0000000000000003", in: pbx)
            .map { String(pbx[$0]) }
        XCTAssertNotNil(block)
        let updated = PbxprojEditor.setOrInsertBuildSetting(block!, key: "MARKETING_VERSION", value: "2.0")
        XCTAssertTrue(updated.contains("MARKETING_VERSION = 2.0;"))
        XCTAssertFalse(updated.contains("MARKETING_VERSION = 1.0;"))
    }

    func testSetOrInsertBuildSettingInsertsNew() throws {
        let block = try PbxprojEditor.blockRange(forConfigurationID: "A100000A0000000000000003", in: pbx)
            .map { String(pbx[$0]) }
        let updated = PbxprojEditor.setOrInsertBuildSetting(block!, key: "CODE_SIGN_ENTITLEMENTS", value: #""LatticeTplApp/LatticeTplApp.entitlements""#)
        XCTAssertTrue(updated.contains("CODE_SIGN_ENTITLEMENTS = \"LatticeTplApp/LatticeTplApp.entitlements\";"))
        // Count occurrences — must be exactly one.
        let count = updated.components(separatedBy: "CODE_SIGN_ENTITLEMENTS").count - 1
        XCTAssertEqual(count, 1)
    }

    func testHexIDsExtracts24CharIDs() {
        let ids = PbxprojEditor.hexIDs(in: "foo A10000010000000000000001 bar B20000020000000000000002")
        XCTAssertEqual(ids, ["A10000010000000000000001", "B20000020000000000000002"])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail (PbxprojEditor does not exist)**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS' -only-testing:LatticeTests/PbxprojEditorTests`
Expected: FAIL — "cannot find 'PbxprojEditor' in scope".

- [ ] **Step 4: Create `PbxprojEditor.swift` with extracted helpers**

Create `Lattice/Lattice/PbxprojEditor.swift`. Move these functions from `ProjectAppIdentityEditor` (currently private static) into a new `enum PbxprojEditor` and make them `internal`:

```swift
import Foundation

/// Shared, low-level helpers for reading and editing `project.pbxproj`.
/// Both `ProjectAppIdentityEditor` and `CapabilityApplicator` use these
/// so there is exactly one correct pbxproj-editing implementation.
enum PbxprojEditor {
    /// PBXNativeTarget application → XCConfigurationList → XCBuildConfiguration ids.
    static func applicationTargetConfigurationIDs(in pbx: String) throws -> [String] {
        // (move body verbatim from ProjectAppIdentityEditor.applicationTargetConfigurationIDs)
    }

    /// Range covering the full `{ ... }` block for a configuration id.
    static func blockRange(forConfigurationID id: String, in pbx: String) -> Range<String.Index>? {
        // (move body verbatim from ProjectAppIdentityEditor.blockRange)
    }

    /// Set a `key = value;` build setting inside a config block, replacing
    /// an existing line or inserting after `buildSettings = {`.
    static func setOrInsertBuildSetting(_ block: String, key: String, value: String) -> String {
        // (move body verbatim from ProjectAppIdentityEditor.setOrInsertBuildSetting)
    }

    /// Extract all 24-char uppercase hex IDs from a string.
    static func hexIDs(in text: String) -> [String] {
        // (move body verbatim from ProjectAppIdentityEditor.hexIDs)
    }

    /// Escape a string for use as a pbxproj build-setting value.
    static func pbxEscape(_ s: String) -> String {
        // (move body verbatim from ProjectAppIdentityEditor.pbxEscape)
    }

    /// Strip surrounding double-quotes and unescape embedded quotes.
    static func stripQuotes(_ s: String) -> String {
        // (move body verbatim from ProjectAppIdentityEditor.stripQuotes)
    }
}
```

Move the bodies verbatim. Do not change the logic.

- [ ] **Step 5: Update `ProjectAppIdentityEditor` to delegate to `PbxprojEditor`**

In `ProjectAppIdentityEditor.swift`, replace the private static functions (`applicationTargetConfigurationIDs`, `blockRange`, `setOrInsertBuildSetting`, `hexIDs`, `pbxEscape`, `stripQuotes`) with thin wrappers calling `PbxprojEditor`, OR update call sites to call `PbxprojEditor` directly. The cleanest approach: delete the private copies and change internal call sites (`applyPbxprojIdentity`, `replaceBuildSettings`) to call `PbxprojEditor.foo(...)`. Keep `findContainedXcodeProj`, `resolveInfoPlistURL`, `mergeInfoPlist`, `readInfoPlistIdentity`, `value(for:in:)` where they are — they're identity-specific.

- [ ] **Step 6: Run the full test suite to verify nothing broke**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: PASS — PbxprojEditor tests pass, SanityTest passes, app target still builds.

- [ ] **Step 7: Commit**

```bash
git add Lattice/Lattice/PbxprojEditor.swift Lattice/LatticeTests/PbxprojEditorTests.swift Lattice/LatticeTests/Fixtures/TemplatePbxproj.swift Lattice/Lattice/ProjectAppIdentityEditor.swift
git commit -m "Extract shared PbxprojEditor from ProjectAppIdentityEditor"
```

---

## Task 2: Add `PbxprojEditor.ensureEntitlementsFileReference`

**Why:** This is the new capability the extracted editor needs — wiring a `.entitlements` file into pbxproj. It's the riskiest edit, so it gets its own task and thorough tests.

**Files:**
- Modify: `Lattice/Lattice/PbxprojEditor.swift`
- Modify: `Lattice/LatticeTests/PbxprojEditorTests.swift`

The function must, given a pbxproj string and an entitlements relative path:
1. Generate a fresh 24-hex ID for the `PBXFileReference` and another for the `PBXBuildFile`.
2. Add a `PBXFileReference` entry in the PBXFileReference section.
3. Add a `PBXBuildFile` entry in the PBXBuildFile section.
4. Add the `PBXBuildFile` id to the app target's `Resources` build phase.
5. Add the `PBXFileReference` id to the app target's source group (`PBXGroup`).
6. Set `CODE_SIGN_ENTITLEMENTS = "<path>";` on every app-target config.
7. Be idempotent: if the entitlements path is already referenced, do nothing and return.

- [ ] **Step 1: Write failing tests**

Append to `PbxprojEditorTests.swift`:

```swift
func testEnsureEntitlementsFileReferenceAddsAllWiring() throws {
    let result = try PbxprojEditor.ensureEntitlementsFileReference(
        in: pbx,
        relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
    )
    XCTAssertTrue(result.wasModified)
    // 1. PBXFileReference entry present
    XCTAssertTrue(result.modifiedPbx.contains(".entitlements\" = {isa = PBXFileReference"))
    // 2. PBXBuildFile entry present (in Resources)
    XCTAssertTrue(result.modifiedPbx.contains("in Resources"))
    // 3. CODE_SIGN_ENTITLEMENTS set on both configs
    let count = result.modifiedPbx.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = ").count - 1
    XCTAssertEqual(count, 2)
}

func testEnsureEntitlementsFileReferenceIsIdempotent() throws {
    let first = try PbxprojEditor.ensureEntitlementsFileReference(
        in: pbx,
        relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
    )
    let second = try PbxprojEditor.ensureEntitlementsFileReference(
        in: first.modifiedPbx,
        relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
    )
    XCTAssertFalse(second.wasModified, "second call must not modify an already-wired project")
}

func testEnsureEntitlementsFileReferenceIDsAreUniqueAnd24Hex() throws {
    let result = try PbxprojEditor.ensureEntitlementsFileReference(
        in: pbx,
        relativePath: "App.entitlements"
    )
    // Find the two new IDs (file ref + build file) and assert they are 24-hex and distinct.
    let newRefs = result.modifiedPbx.components(separatedBy: "App.entitlements")
    // The new IDs should not collide with existing template IDs (A1...).
    XCTAssertFalse(result.modifiedPbx.contains("A1000001000000000000000F")) // sentinel — placeholder logic
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:LatticeTests/PbxprojEditorTests`
Expected: FAIL — `ensureEntitlementsFileReference` does not exist.

- [ ] **Step 3: Implement `ensureEntitlementsFileReference`**

Add to `PbxprojEditor.swift`:

```swift
struct EntitlementsWiringResult {
    let modifiedPbx: String
    let wasModified: Bool
    let fileReferenceID: String?
    let buildFileID: String?
}

extension PbxprojEditor {
    /// Wire a `.entitlements` file into the project: file reference, build file,
    /// resources phase, group membership, and `CODE_SIGN_ENTITLEMENTS` build setting.
    /// Idempotent — returns `wasModified: false` if already wired.
    static func ensureEntitlementsFileReference(
        in pbx: String,
        relativePath: String,
        fileName: String = "entitlements"
    ) throws -> EntitlementsWiringResult {
        // 1. Idempotency check: is CODE_SIGN_ENTITLEMENTS already set to this path?
        let settingValue = pbxEscape(relativePath)
        if pbx.contains("CODE_SIGN_ENTITLEMENTS = \(settingValue);") {
            return EntitlementsWiringResult(modifiedPbx: pbx, wasModified: false, fileReferenceID: nil, buildFileID: nil)
        }

        // 2. Generate unique 24-hex IDs that don't collide with existing ones.
        let existingIDs = Set(hexIDs(in: pbx))
        let fileRefID = generateUniqueHexID(avoiding: existingIDs)
        var taken = existingIDs.union([fileRefID])
        let buildFileID = generateUniqueHexID(avoiding: taken)

        // 3. Determine the app target's Resources build phase id and source group id.
        //    (Parse from the PBXNativeTarget application block — reuse applicationTargetConfigurationIDs pattern.)
        let resourcesBuildPhaseID = try findResourcesBuildPhaseID(in: pbx)
        let sourceGroupID = try findSourceGroupID(in: pbx)
        let appConfigIDs = try applicationTargetConfigurationIDs(in: pbx)

        let entitlementsBaseName = (relativePath as NSString).lastPathComponent

        var text = pbx

        // 4. Insert PBXFileReference before "/* End PBXFileReference section */"
        let fileRefLine = "\t\t\(fileRefID) /* \(entitlementsBaseName) */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = \(entitlementsBaseName); sourceTree = \"<group>\"; };\n"
        text = insertBeforeSectionMarker("End PBXFileReference section", line: fileRefLine, in: text)

        // 5. Insert PBXBuildFile before "/* End PBXBuildFile section */"
        let buildFileLine = "\t\t\(buildFileID) /* \(entitlementsBaseName) in Resources */ = {isa = PBXBuildFile; fileRef = \(fileRefID) /* \(entitlementsBaseName) */; };\n"
        text = insertBeforeSectionMarker("End PBXBuildFile section", line: buildFileLine, in: text)

        // 6. Add build file id to the Resources build phase files list.
        text = addToBuildPhaseFiles(resourcesBuildPhaseID, buildFileID: buildFileID, comment: "\(entitlementsBaseName) in Resources", in: text)

        // 7. Add file reference id to the source group children.
        text = addToGroupChildren(sourceGroupID, fileRefID: fileRefID, comment: entitlementsBaseName, in: text)

        // 8. Set CODE_SIGN_ENTITLEMENTS on every app-target config block.
        for id in appConfigIDs {
            guard let range = blockRange(forConfigurationID: id, in: text) else { continue }
            let block = String(text[range])
            let updated = setOrInsertBuildSetting(block, key: "CODE_SIGN_ENTITLEMENTS", value: settingValue)
            text.replaceSubrange(range, with: updated)
        }

        return EntitlementsWiringResult(modifiedPbx: text, wasModified: true, fileReferenceID: fileRefID, buildFileID: buildFileID)
    }

    // MARK: - ID generation

    /// Generate a 24-char uppercase-hex ID not present in `existing`.
    static func generateUniqueHexID(avoiding existing: Set<String>) -> String {
        var id = ""
        repeat {
            id = (0..<24).map { _ in "0123456789ABCDEF".randomElement()! }.joined()
        } while existing.contains(id)
        return id
    }

    // MARK: - Section / phase parsing helpers

    /// Insert `line` immediately before the marker line `/* <marker> */`.
    private static func insertBeforeSectionMarker(_ marker: String, line: String, in pbx: String) -> String {
        guard let range = pbx.range(of: "/* \(marker) */") else { return pbx }
        var out = pbx
        out.insert(contentsOf: line, at: range.lowerBound)
        return out
    }

    /// Find the Resources build phase id of the application target.
    private static func findResourcesBuildPhaseID(in pbx: String) throws -> String {
        // In the PBXNativeTarget application block, the buildPhases array lists phase ids
        // with comments like "/* Resources */". Find the one whose comment is "Resources".
        guard let appRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            throw PbxprojEditorError.noApplicationTarget
        }
        let head = pbx[..<appRange.lowerBound]
        guard let targetStart = head.range(of: "\t\t", options: .backwards)?.lowerBound else {
            throw PbxprojEditorError.noApplicationTarget
        }
        let targetBlock = pbx[targetStart..<appRange.upperBound]
        // Find "/* Resources */" within the buildPhases of this target.
        guard let resRange = targetBlock.range(of: "/* Resources */") else {
            throw PbxprojEditorError.resourcesBuildPhaseNotFound
        }
        let before = targetBlock[..<resRange.lowerBound]
        guard let space = before.lastIndex(of: " ") else {
            throw PbxprojEditorError.resourcesBuildPhaseNotFound
        }
        return String(before[before.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Find the source group id (the group named after the product, containing the .swift files).
    private static func findSourceGroupID(in pbx: String) throws -> String {
        // Heuristic: the PBXGroup whose children include a .swift fileRef.
        // For the template, this is A10000050000000000000002. We locate it by
        // finding "LatticeTplAppApp.swift */" inside a group's children list.
        guard let swiftRef = pbx.range(of: "/* LatticeTplAppApp.swift */") else {
            throw PbxprojEditorError.sourceGroupNotFound
        }
        // Walk backwards to the enclosing group id line.
        let before = pbx[..<swiftRef.lowerBound]
        guard let groupOpen = before.range(of: "/* */ = {\n\t\t\tisa = PBXGroup;", options: .backwards) else {
            // Fallback: find the PBXGroup that contains the swift fileRef in its children.
            throw PbxprojEditorError.sourceGroupNotFound
        }
        // The group id is the 24-hex token before the "/* ... */ = {" line.
        let groupLine = pbx[..<groupOpen.upperBound]
        let ids = hexIDs(in: String(groupLine))
        guard let last = ids.last else { throw PbxprojEditorError.sourceGroupNotFound }
        return last
    }

    private static func addToBuildPhaseFiles(_ phaseID: String, buildFileID: String, comment: String, in pbx: String) -> String {
        // Insert "\t\t\t\t<buildFileID> /* <comment> */,\n" into the files = ( ... ) of phaseID.
        guard let phaseRange = pbx.range(of: "\t\t\(phaseID) /*") else { return pbx }
        let after = pbx[phaseRange.upperBound...]
        guard let filesRange = after.range(of: "files = (") else { return pbx }
        let insertAt = filesRange.upperBound
        let insertion = "\n\t\t\t\t\(buildFileID) /* \(comment) */,"
        var out = pbx
        out.insert(contentsOf: insertion, at: phaseRange.upperBound + (insertAt - after.startIndex))
        // NOTE: index math must be relative to `pbx`, not `after`. The line above
        // computes the offset correctly because phaseRange.upperBound + relative offset.
        return out
    }

    private static func addToGroupChildren(_ groupID: String, fileRefID: String, comment: String, in pbx: String) -> String {
        // Insert "\t\t\t\t<fileRefID> /* <comment> */,\n" into children = ( ... ) of groupID.
        guard let groupRange = pbx.range(of: "\t\t\(groupID) /*") else { return pbx }
        let after = pbx[groupRange.upperBound...]
        guard let childrenRange = after.range(of: "children = (") else { return pbx }
        let insertion = "\n\t\t\t\t\(fileRefID) /* \(comment) */,"
        var out = pbx
        let absoluteInsertAt = groupRange.upperBound + (childrenRange.upperBound - after.startIndex)
        out.insert(contentsOf: insertion, at: absoluteInsertAt)
        return out
    }
}

enum PbxprojEditorError: LocalizedError {
    case noApplicationTarget
    case resourcesBuildPhaseNotFound
    case sourceGroupNotFound

    var errorDescription: String? {
        switch self {
        case .noApplicationTarget: return "No application target found in project.pbxproj."
        case .resourcesBuildPhaseNotFound: return "Could not locate the Resources build phase of the app target."
        case .sourceGroupNotFound: return "Could not locate the source group of the app target."
        }
    }
}
```

**Implementer note:** The index math in `addToBuildPhaseFiles` / `addToGroupChildren` is subtle because `after` is a substring with a different base index than `pbx`. The pattern `groupRange.upperBound + (childIndex - after.startIndex)` is WRONG as written because `Range<String.Index>` arithmetic doesn't work that way with substrings. Instead, use this corrected approach:

```swift
private static func addToGroupChildren(_ groupID: String, fileRefID: String, comment: String, in pbx: String) -> String {
    guard let groupRange = pbx.range(of: "\t\t\(groupID) /*") else { return pbx }
    let searchStart = groupRange.upperBound
    let searchRegion = pbx[searchStart...]
    guard let childrenRange = searchRegion.range(of: "children = (") else { return pbx }
    // childrenRange.upperBound is an index into the `searchRegion` substring.
    // Convert back to a `pbx` index:
    let absoluteInsertAt = pbx.index(childrenRange.upperBound, offsetBy: 0, limitedBy: pbx.endIndex) ?? pbx.endIndex
    // Actually, since searchRegion shares storage with pbx, indices in searchRegion ARE valid in pbx.
    let insertion = "\n\t\t\t\t\(fileRefID) /* \(comment) */,"
    var out = pbx
    out.insert(contentsOf: insertion, at: childrenRange.upperBound)
    return out
}
```

**Key fact:** `String` substrings share indices with their base string in Swift. `pbx[searchStart...].range(of:)` returns indices that are valid in `pbx` too. So `childrenRange.upperBound` can be used directly in `out.insert(contentsOf:at:)`. Use this pattern in both helper functions. Remove the incorrect `phaseRange.upperBound + offset` math.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS' -only-testing:LatticeTests/PbxprojEditorTests`
Expected: PASS — all entitlements wiring tests pass, idempotency confirmed.

- [ ] **Step 5: Verify the modified pbxproj parses with `plutil`**

Add an integration check in the test that writes the modified pbxproj to a temp file and validates it:

```swift
func testModifiedPbxprojIsValidPlist() throws {
    let result = try PbxprojEditor.ensureEntitlementsFileReference(
        in: pbx,
        relativePath: "LatticeTplApp/LatticeTplApp.entitlements"
    )
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.pbxproj")
    try result.modifiedPbx.write(to: tmp, atomically: true, encoding: .utf8)
    // plutil -lint confirms the file is syntactically valid.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    proc.arguments = ["-lint", tmp.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try proc.run()
    proc.waitUntilExit()
    XCTAssertEqual(proc.terminationStatus, 0, "modified pbxproj must be valid")
}
```

Run: `xcodebuild test ... -only-testing:LatticeTests/PbxprojEditorTests/testModifiedPbxprojIsValidPlist`
Expected: PASS — plutil confirms the file is valid.

- [ ] **Step 6: Commit**

```bash
git add Lattice/Lattice/PbxprojEditor.swift Lattice/LatticeTests/PbxprojEditorTests.swift
git commit -m "Add PbxprojEditor.ensureEntitlementsFileReference with idempotent wiring"
```

---

## Task 3: Build the `AppleCapabilityCatalog`

**Why:** This is the pure-data source of truth. No I/O, trivially testable. The applicator depends on it.

**Files:**
- Create: `Lattice/Lattice/AppleCapabilityCatalog.swift`
- Create: `Lattice/LatticeTests/AppleCapabilityCatalogTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Lattice/LatticeTests/AppleCapabilityCatalogTests.swift`:

```swift
import XCTest
@testable import Lattice

final class AppleCapabilityCatalogTests: XCTestCase {
    func testCatalogHasFiveCapabilities() {
        XCTAssertEqual(AppleCapabilityCatalog.all.count, 5)
    }

    func testCapabilityIDsAreUnique() {
        let ids = AppleCapabilityCatalog.all.map(\.id)
        XCTAssertEqual(ids, Array(Set(ids)), "capability ids must be unique")
    }

    func testEveryCapabilityHasDisplayNameSummaryAndPlatform() {
        for cap in AppleCapabilityCatalog.all {
            XCTAssertFalse(cap.displayName.isEmpty, "\(cap.id) missing displayName")
            XCTAssertFalse(cap.summary.isEmpty, "\(cap.id) missing summary")
            XCTAssertFalse(cap.applicablePlatforms.isEmpty, "\(cap.id) has no platforms")
        }
    }

    func testLookupByID() {
        let cap = AppleCapabilityCatalog.capability(id: "app_groups")
        XCTAssertNotNil(cap)
        XCTAssertEqual(cap?.displayName, "App Groups")
    }

    func testLookupUnknownIDReturnsNil() {
        XCTAssertNil(AppleCapabilityCatalog.capability(id: "nonexistent"))
    }

    func testAppGroupsDeclaresEntitlementKey() {
        let cap = AppleCapabilityCatalog.capability(id: "app_groups")!
        XCTAssertTrue(cap.entitlements.contains { $0.key == "com.apple.security.application-groups" })
    }

    func testPushNotificationsDeclaresApsEnvironmentAndBackgroundModes() {
        let cap = AppleCapabilityCatalog.capability(id: "push_notifications")!
        XCTAssertTrue(cap.entitlements.contains { $0.key == "aps-environment" })
        XCTAssertTrue(cap.infoPlistKeys.contains { $0.key == "UIBackgroundModes" })
    }

    func testPushNotificationsDeclaresUserNotificationsFramework() {
        let cap = AppleCapabilityCatalog.capability(id: "push_notifications")!
        XCTAssertTrue(cap.frameworks.contains("UserNotifications.framework"))
    }

    func testStorekitHasNoEntitlements() {
        let cap = AppleCapabilityCatalog.capability(id: "storekit")!
        XCTAssertTrue(cap.entitlements.isEmpty)
    }

    func testBackgroundModesHasNoEntitlementsOnlyPlist() {
        let cap = AppleCapabilityCatalog.capability(id: "background_modes")!
        XCTAssertTrue(cap.entitlements.isEmpty)
        XCTAssertTrue(cap.infoPlistKeys.contains { $0.key == "UIBackgroundModes" })
    }

    func testCapabilitiesWithProvisioningNeedsHaveNotes() {
        // App Groups, Push, Keychain all need portal steps.
        for id in ["app_groups", "push_notifications", "keychain_sharing"] {
            let cap = AppleCapabilityCatalog.capability(id: id)!
            XCTAssertNotNil(cap.provisioningNotes, "\(id) should have provisioning notes")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:LatticeTests/AppleCapabilityCatalogTests`
Expected: FAIL — "cannot find 'AppleCapabilityCatalog' in scope".

- [ ] **Step 3: Implement `AppleCapabilityCatalog.swift`**

Create `Lattice/Lattice/AppleCapabilityCatalog.swift`:

```swift
import Foundation

/// The set of Apple platforms a capability can apply to.
enum ApplePlatform: String, CaseIterable {
    case iOS
    case macOS
    case watchOS
}

/// A single entitlement key/value pair to merge into the `.entitlements` plist.
struct EntitlementEntry: Equatable {
    let key: String
    let value: EntitlementValue
}

/// The shape of an entitlement value. Matches what plist serialization accepts.
enum EntitlementValue: Equatable {
    case string(String)
    case stringArray([String])
    case boolean(Bool)
    case placeholder(String) // "$(AppIdentifierPrefix)..." resolved at apply time

    /// The value as it should be written into the entitlements plist.
    var plistValue: Any {
        switch self {
        case .string(let s): return s
        case .stringArray(let a): return a
        case .boolean(let b): return b
        case .placeholder(let p): return p
        }
    }
}

/// A single Info.plist key/value pair.
struct PlistEntry: Equatable {
    let key: String
    let value: Any

    static func == (lhs: PlistEntry, rhs: PlistEntry) -> Bool {
        return lhs.key == rhs.key
    }
}

/// A complete description of an Apple capability's file-side requirements.
/// This is pure data — no I/O. The applicator consumes it.
struct AppleCapability: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let entitlements: [EntitlementEntry]
    let infoPlistKeys: [PlistEntry]
    let frameworks: [String]
    let provisioningNotes: String?
    let applicablePlatforms: Set<ApplePlatform>
}

/// The single source of truth for supported capabilities.
/// Adding a capability = adding a static constant and an `all` entry.
enum AppleCapabilityCatalog {
    static let appGroups = AppleCapability(
        id: "app_groups",
        displayName: "App Groups",
        summary: "Share data between your app and its extensions via a shared container.",
        entitlements: [
            EntitlementEntry(
                key: "com.apple.security.application-groups",
                value: .placeholder("$(AppGroupIdentifier)") // resolved from parameters at apply time
            )
        ],
        infoPlistKeys: [],
        frameworks: [],
        provisioningNotes: "Create the App Group in the Apple Developer Portal (Identifiers → App Groups), then enable it under Xcode → Signing & Capabilities for your app and any extensions that share it.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let pushNotifications = AppleCapability(
        id: "push_notifications",
        displayName: "Push Notifications",
        summary: "Receive remote notifications via APNs.",
        entitlements: [
            EntitlementEntry(key: "aps-environment", value: .placeholder("$(APSEnvironment)")) // "development" or "production"
        ],
        infoPlistKeys: [
            PlistEntry(key: "UIBackgroundModes", value: ["remote-notification"])
        ],
        frameworks: ["UserNotifications.framework"],
        provisioningNotes: "Enable the Push Notifications capability in the Apple Developer Portal for your App ID, and upload an APNs authentication key (or certificate) at developer.apple.com → Account → Certificates, Identifiers & Profiles → Keys.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let storekit = AppleCapability(
        id: "storekit",
        displayName: "StoreKit",
        summary: "Sell in-app purchases and subscriptions using StoreKit 2.",
        entitlements: [],
        infoPlistKeys: [],
        frameworks: ["StoreKit.framework"],
        provisioningNotes: "Configure your in-app purchases and subscriptions in App Store Connect → Your App → In-App Purchases. No entitlement key is required, but the In-App Purchase capability must be enabled for your App ID in the Developer Portal.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let keychainSharing = AppleCapability(
        id: "keychain_sharing",
        displayName: "Keychain Sharing",
        summary: "Share keychain items between apps from the same team.",
        entitlements: [
            EntitlementEntry(
                key: "keychain-access-groups",
                value: .placeholder("$(KeychainAccessGroup)") // typically $(AppIdentifierPrefix)com.example.shared
            )
        ],
        infoPlistKeys: [],
        frameworks: [],
        provisioningNotes: "Enable the Keychain Sharing capability in Xcode → Signing & Capabilities. The access group prefix $(AppIdentifierPrefix) is replaced at build time with your team's identifier.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let backgroundModes = AppleCapability(
        id: "background_modes",
        displayName: "Background Modes",
        summary: "Declare the background tasks your app needs to run.",
        entitlements: [],
        infoPlistKeys: [
            PlistEntry(key: "UIBackgroundModes", value: .placeholder("$(BackgroundModes)")) // array, e.g. ["audio", "fetch"]
        ],
        frameworks: [],
        provisioningNotes: nil,
        applicablePlatforms: [.iOS]
    )

    /// All supported capabilities, in display order.
    static let all: [AppleCapability] = [
        appGroups,
        pushNotifications,
        storekit,
        keychainSharing,
        backgroundModes,
    ]

    /// Look up a capability by id. Returns nil if unknown.
    static func capability(id: String) -> AppleCapability? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS' -only-testing:LatticeTests/AppleCapabilityCatalogTests`
Expected: PASS — all catalog tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lattice/Lattice/AppleCapabilityCatalog.swift Lattice/LatticeTests/AppleCapabilityCatalogTests.swift
git commit -m "Add AppleCapabilityCatalog with 5 initial capabilities"
```

---

## Task 4: Build `CapabilityApplicator.apply`

**Why:** This turns a catalog entry into real file changes. Apply comes before remove (remove needs apply's merge helpers).

**Files:**
- Create: `Lattice/Lattice/CapabilityApplicator.swift`
- Create: `Lattice/LatticeTests/CapabilityApplicatorTests.swift`
- Create: `Lattice/LatticeTests/Fixtures/MinimalProjectHelper.swift`

- [ ] **Step 1: Create a fixture project helper**

Create `Lattice/LatticeTests/Fixtures/MinimalProjectHelper.swift`:

```swift
import Foundation

/// Creates a minimal on-disk project fixture for applicator tests:
/// a folder containing a copy of the iOS template .xcodeproj.
enum MinimalProjectFixture {
    /// Returns the URL of the fixture project root. Caller should delete it after use.
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Copy the template .xcodeproj into the fixture dir.
        let templateProj = URL(fileURLWithPath: #"\#${SRCROOT}"#) // placeholder — see note
        // NOTE: In tests, resolve the template path relative to the test bundle.
        // Alternative: ship the template content as a string fixture (preferred for hermeticity).
        // Use PbxprojFixtures.iosTemplate and write it to disk:
        let projDir = dir.appendingPathComponent("TestApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try PbxprojFixtures.iosTemplate.write(
            to: projDir.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        // Create the source group folder so entitlements path resolves.
        let srcDir = dir.appendingPathComponent("TestApp")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        return dir
    }

    static func tearDown(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

**Implementer note:** Remove the broken `#"\#${SRCROOT}"#` line — it's a leftover. The fixture writes `PbxprojFixtures.iosTemplate` to disk, which is hermetic. Also rename the template's app to "TestApp" in your head — but since the fixture uses the literal template string (which references `LatticeTplApp`), the entitlements path will be `LatticeTplApp/LatticeTplApp.entitlements`. That's fine for tests; the applicator derives the path from the project, not the fixture name. Keep the `TestApp` source dir creation but make it `LatticeTplApp` to match:

```swift
let srcDir = dir.appendingPathComponent("LatticeTplApp")
try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
```

- [ ] **Step 2: Write failing tests for apply**

Create `Lattice/LatticeTests/CapabilityApplicatorTests.swift`:

```swift
import XCTest
@testable import Lattice

final class CapabilityApplicatorTests: XCTestCase {
    var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = try MinimalProjectFixture.make()
    }

    override func tearDownWithError() throws {
        if fixtureRoot != nil { MinimalProjectFixture.tearDown(fixtureRoot) }
    }

    func testApplyBackgroundModesAddsPlistKey() async throws {
        let result = try await CapabilityApplicator.apply(
            capability: .backgroundModes,
            to: fixtureRoot,
            parameters: ["UIBackgroundModes": ["audio", "fetch"]]
        )
        XCTAssertTrue(result.changedFiles.contains { $0.pathExtension == "plist" } || result.changedFiles.contains { $0.lastPathComponent == "project.pbxproj" })
        // Background modes has no entitlements, so no .entitlements file should be created.
        XCTAssertFalse(result.changedFiles.contains { $0.pathExtension == "entitlements" })
    }

    func testApplyAppGroupsCreatesEntitlementsFileAndMergesKey() async throws {
        let result = try await CapabilityApplicator.apply(
            capability: .appGroups(groupIdentifiers: ["group.com.example.app"]),
            to: fixtureRoot,
            parameters: [:]
        )
        // Entitlements file created.
        let entFile = result.changedFiles.first { $0.pathExtension == "entitlements" }
        XCTAssertNotNil(entFile)
        let content = try String(contentsOf: entFile!, encoding: .utf8)
        XCTAssertTrue(content.contains("com.apple.security.application-groups"))
        XCTAssertTrue(content.contains("group.com.example.app"))
    }

    func testApplyIsIdempotent() async throws {
        let first = try await CapabilityApplicator.apply(
            capability: .appGroups(groupIdentifiers: ["group.com.example.app"]),
            to: fixtureRoot,
            parameters: [:]
        )
        let second = try await CapabilityApplicator.apply(
            capability: .appGroups(groupIdentifiers: ["group.com.example.app"]),
            to: fixtureRoot,
            parameters: [:]
        )
        XCTAssertTrue(second.alreadyPresent.contains("com.apple.security.application-groups"),
                      "second apply should report the key as already present")
    }

    func testApplyAppGroupsMergesMultipleIdentifiersUniquely() async throws {
        _ = try await CapabilityApplicator.apply(
            capability: .appGroups(groupIdentifiers: ["group.com.example.one"]),
            to: fixtureRoot,
            parameters: [:]
        )
        let second = try await CapabilityApplicator.apply(
            capability: .appGroups(groupIdentifiers: ["group.com.example.one", "group.com.example.two"]),
            to: fixtureRoot,
            parameters: [:]
        )
        let entFile = second.changedFiles.first { $0.pathExtension == "entitlements" }!
        let dict = NSDictionary(contentsOf: entFile) as? [String: Any]
        let groups = dict?["com.apple.security.application-groups"] as? [String]
        XCTAssertEqual(Set(groups ?? []), ["group.com.example.one", "group.com.example.two"])
    }

    func testApplyUnknownCapabilityThrows() async {
        do {
            _ = try await CapabilityApplicator.apply(
                capabilityId: "nonexistent",
                to: fixtureRoot,
                parameters: [:]
            )
            XCTFail("expected unknownCapability error")
        } catch CapabilityApplicatorError.unknownCapability(let id) {
            XCTAssertEqual(id, "nonexistent")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:LatticeTests/CapabilityApplicatorTests`
Expected: FAIL — `CapabilityApplicator` does not exist.

- [ ] **Step 4: Implement `CapabilityApplicator.swift`**

Create `Lattice/Lattice/CapabilityApplicator.swift`:

```swift
import Foundation

struct CapabilityApplyResult {
    let changedFiles: [URL]
    let alreadyPresent: [String]   // keys that were already set before this apply
    let manualSteps: String?       // provisioning note
}

enum CapabilityApplicatorError: LocalizedError {
    case noXcodeProject
    case noApplicationTarget
    case unknownCapability(String)
    case missingParameter(String)
    case entitlementsWriteFailed(String)
    case pbxprojParseFailure(String)
    case notApplicableToPlatform(String, ApplePlatform)

    var errorDescription: String? {
        switch self {
        case .noXcodeProject: return "No Xcode project found in this folder."
        case .noApplicationTarget: return "Could not find an application target in the Xcode project."
        case .unknownCapability(let id): return "Unknown capability: \(id)."
        case .missingParameter(let detail): return "Missing required parameter: \(detail)."
        case .entitlementsWriteFailed(let msg): return "Could not write entitlements file: \(msg)."
        case .pbxprojParseFailure(let msg): return "Could not parse project.pbxproj: \(msg)."
        case .notApplicableToPlatform(let id, let p): return "Capability \(id) is not applicable to \(p.rawValue)."
        }
    }
}

enum CapabilityApplicator {
    // MARK: - Apply

    static func apply(
        capabilityId: String,
        to projectRoot: URL,
        parameters: [String: Any]
    ) async throws -> CapabilityApplyResult {
        guard let cap = AppleCapabilityCatalog.capability(id: capabilityId) else {
            throw CapabilityApplicatorError.unknownCapability(capabilityId)
        }
        return try await apply(capability: cap, to: projectRoot, parameters: parameters)
    }

    /// Convenience overload taking a resolved `AppleCapability` (used by UI + tests).
    static func apply(
        capability: AppleCapability,
        to projectRoot: URL,
        parameters: [String: Any]
    ) async throws -> CapabilityApplyResult {
        var changedFiles: [URL] = []
        var alreadyPresent: [String] = []

        // 1. Locate the project file.
        let projURL = try findXcodeProj(projectRoot: projectRoot)
        let pbxPath = projURL.appendingPathComponent("project.pbxproj")
        var pbxText = try String(contentsOf: pbxPath, encoding: .utf8)

        // 2. Resolve placeholders in entitlements/plist values from `parameters`.
        let resolvedEntitlements = resolveEntitlements(cap.entitlements, parameters: parameters)
        let resolvedPlistEntries = resolvePlistEntries(cap.infoPlistKeys, parameters: parameters)

        // 3. If the capability has entitlement keys, ensure an entitlements file exists & wired.
        var entitlementsFileURL: URL?
        if !resolvedEntitlements.isEmpty {
            let (newPbx, entURL, entCreated) = try ensureEntitlementsFile(in: pbxText, projectRoot: projectRoot, pbxPath: pbxPath)
            pbxText = newPbx
            entitlementsFileURL = entURL
            if entCreated { changedFiles.append(pbxPath) }
            changedFiles.append(entURL)
        }

        // 4. Merge entitlement keys (idempotent).
        if let entURL = entitlementsFileURL, !resolvedEntitlements.isEmpty {
            let mergedKeys = mergeEntitlements(into: entURL, entries: resolvedEntitlements)
            alreadyPresent.append(contentsOf: mergedKeys.alreadyPresent)
            if !mergedKeys.changedKeys.isEmpty {
                changedFiles.append(entURL)
            }
        }

        // 5. Merge Info.plist keys (idempotent).
        //    The template uses GENERATE_INFOPLIST_FILE = YES, so there's no Info.plist on disk.
        //    For plist-only capabilities (background_modes), we set INFOPLIST_KEY_* build settings
        //    in pbxproj instead. For array values like UIBackgroundModes, Xcode expects
        //    INFOPLIST_KEY_UIBackgroundModes OR a real Info.plist. We handle both:
        //    - If an Info.plist exists on disk, merge into it.
        //    - Otherwise, add INFOPLIST_KEY_<key> build settings.
        if !resolvedPlistEntries.isEmpty {
            if let plistURL = try? findInfoPlist(projectRoot: projectRoot, pbxText: pbxText) {
                let mergedPlist = mergeInfoPlistEntries(into: plistURL, entries: resolvedPlistEntries)
                alreadyPresent.append(contentsOf: mergedPlist.alreadyPresent)
                changedFiles.append(plistURL)
            } else {
                // Write INFOPLIST_KEY_<key> build settings for scalars; for arrays (like
                // UIBackgroundModes) we fall back to creating an Info.plist on disk because
                // Xcode's INFOPLIST_KEY_ scheme does not handle arrays well.
                let (newPbx, createdPlist) = try applyPlistEntriesViaBuildSettingsOrFile(
                    pbxText, entries: resolvedPlistEntries, projectRoot: projectRoot, pbxPath: pbxPath
                )
                pbxText = newPbx
                changedFiles.append(pbxPath)
                if let createdURL = createdPlist { changedFiles.append(createdURL) }
            }
        }

        // 6. Write the modified pbxproj if it changed.
        try pbxText.data(using: .utf8)?.write(to: pbxPath, options: .atomic)
        // (We write unconditionally for simplicity; the result reflects logical changes.)

        return CapabilityApplyResult(
            changedFiles: Array(Set(changedFiles)),
            alreadyPresent: alreadyPresent,
            manualSteps: cap.provisioningNotes
        )
    }

    // MARK: - Entitlements file management

    /// Ensure a `.entitlements` file exists and is wired into pbxproj.
    /// Returns (modified pbx text, entitlements file URL, whether pbx was modified).
    private static func ensureEntitlementsFile(
        in pbxText: String,
        projectRoot: URL,
        pbxPath: URL
    ) throws -> (String, URL, Bool) {
        // Derive the entitlements relative path from the app target name.
        let targetName = try appNameFromPbxproj(pbxText)
        let entitlementsRelPath = "\(targetName)/\(targetName).entitlements"
        let entURL = projectRoot.appendingPathComponent(entitlementsRelPath)

        let wiring = try PbxprojEditor.ensureEntitlementsFileReference(in: pbxText, relativePath: entitlementsRelPath)

        // Create the file on disk if it doesn't exist (empty plist root).
        if !FileManager.default.fileExists(atPath: entURL.path) {
            try FileManager.default.createDirectory(at: entURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let emptyPlist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict/>\n</plist>\n"
            try emptyPlist.write(to: entURL, atomically: true, encoding: .utf8)
        }

        return (wiring.modifiedPbx, entURL, wiring.wasModified)
    }

    private struct MergeResult {
        let changedKeys: [String]
        let alreadyPresent: [String]
    }

    /// Merge entitlement entries into the plist at `url`. Returns which keys were newly
    /// added vs already present. Arrays are merged uniquely.
    private static func mergeEntitlements(into url: URL, entries: [EntitlementEntry]) -> MergeResult {
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else {
            return MergeResult(changedKeys: [], alreadyPresent: [])
        }
        var changed: [String] = []
        var present: [String] = []

        for entry in entries {
            if let existing = plist[entry.key] {
                present.append(entry.key)
                // Merge arrays uniquely.
                if let existingArr = existing as? [String], case .stringArray(let newArr) = entry.value {
                    let merged = Array(Set(existingArr + newArr)).sorted()
                    plist[entry.key] = merged
                    if Set(merged) != Set(existingArr) { changed.append(entry.key) }
                }
                // Scalars: overwrite if different.
                else {
                    let newVal = entry.value.plistValue
                    if !isEqualPlistValue(existing, newVal) {
                        plist[entry.key] = newVal
                        changed.append(entry.key)
                    }
                }
            } else {
                plist[entry.key] = entry.value.plistValue
                changed.append(entry.key)
            }
        }

        plist.write(toFile: url.path, atomically: true)
        return MergeResult(changedKeys: changed, alreadyPresent: present)
    }

    // MARK: - Plist (Info.plist) management

    private static func findInfoPlist(projectRoot: URL, pbxText: String) throws -> URL? {
        // Look for INFOPLIST_FILE build setting in the app target configs.
        let configIDs = try PbxprojEditor.applicationTargetConfigurationIDs(in: pbxText)
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbxText) else { continue }
            let block = String(pbxText[range])
            if let val = extractBuildSettingValue(block, key: "INFOPLIST_FILE") {
                let path = PbxprojEditor.stripQuotes(val)
                    .replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
                  .replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private static func mergeInfoPlistEntries(into url: URL, entries: [PlistEntry]) -> MergeResult {
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else {
            return MergeResult(changedKeys: [], alreadyPresent: [])
        }
        var changed: [String] = []
        var present: [String] = []
        for entry in entries {
            if plist[entry.key] != nil {
                present.append(entry.key)
                if let existing = plist[entry.key] as? [String], let newVal = entry.value as? [String] {
                    let merged = Array(Set(existing + newVal)).sorted()
                    plist[entry.key] = merged
                    if Set(merged) != Set(existing) { changed.append(entry.key) }
                } else if !isEqualPlistValue(plist[entry.key], entry.value) {
                    plist[entry.key] = entry.value
                    changed.append(entry.key)
                }
            } else {
                plist[entry.key] = entry.value
                changed.append(entry.key)
            }
        }
        plist.write(toFile: url.path, atomically: true)
        return MergeResult(changedKeys: changed, alreadyPresent: present)
    }

    /// When no Info.plist exists on disk (GENERATE_INFOPLIST_FILE = YES), set
    /// INFOPLIST_KEY_<key> build settings for scalar values. For arrays, create an
    /// Info.plist file because Xcode's INFOPLIST_KEY_ scheme doesn't handle arrays.
    private static func applyPlistEntriesViaBuildSettingsOrFile(
        _ pbxText: String,
        entries: [PlistEntry],
        projectRoot: URL,
        pbxPath: URL
    ) throws -> (String, URL?) {
        var text = pbxText
        var createdPlist: URL?

        let configIDs = try PbxprojEditor.applicationTargetConfigurationIDs(in: text)
        for entry in entries {
            if let arr = entry.value as? [String] {
                // Arrays need a real Info.plist. Create one if not yet created this apply.
                if createdPlist == nil {
                    let plistURL = projectRoot.appendingPathComponent("Info.plist")
                    let initial: [String: Any] = [entry.key: arr]
                    (initial as NSDictionary).write(toFile: plistURL.path, atomically: true)
                    createdPlist = plistURL
                    // Set INFOPLIST_FILE build setting so Xcode uses it.
                    for id in configIDs {
                        guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: text) else { continue }
                        var block = String(text[range])
                        block = PbxprojEditor.setOrInsertBuildSetting(block, key: "INFOPLIST_FILE", value: PbxprojEditor.pbxEscape("Info.plist"))
                        // Turn off GENERATE_INFOPLIST_FILE so our file is used.
                        block = PbxprojEditor.setOrInsertBuildSetting(block, key: "GENERATE_INFOPLIST_FILE", value: "NO")
                        text.replaceSubrange(range, with: block)
                    }
                } else {
                    // Merge into the created file.
                    let merged = mergeInfoPlistEntries(into: createdPlist!, entries: [entry])
                    _ = merged
                }
            } else {
                // Scalar: use INFOPLIST_KEY_<key> build setting.
                let settingKey = "INFOPLIST_KEY_\(entry.key)"
                let valueStr = PbxprojEditor.pbxEscape("\(entry.value)")
                for id in configIDs {
                    guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: text) else { continue }
                    var block = String(text[range])
                    block = PbxprojEditor.setOrInsertBuildSetting(block, key: settingKey, value: valueStr)
                    text.replaceSubrange(range, with: block)
                }
            }
        }
        return (text, createdPlist)
    }

    // MARK: - Placeholder resolution

    /// Replace placeholder entitlement values with concrete values from parameters.
    private static func resolveEntitlements(_ entries: [EntitlementEntry], parameters: [String: Any]) -> [EntitlementEntry] {
        entries.compactMap { entry -> EntitlementEntry? in
            switch entry.value {
            case .placeholder(let token):
                // token like "$(AppGroupIdentifier)" → look up "AppGroupIdentifier" in parameters.
                let key = placeholderName(token) // "AppGroupIdentifier"
                if let val = parameters[key] {
                    if let arr = val as? [String] { return EntitlementEntry(key: entry.key, value: .stringArray(arr)) }
                    if let s = val as? String { return EntitlementEntry(key: entry.key, value: .string(s)) }
                }
                return nil // parameter not provided — skip this entry
            default:
                return entry
            }
        }
    }

    private static func resolvePlistEntries(_ entries: [PlistEntry], parameters: [String: Any]) -> [PlistEntry] {
        entries.compactMap { entry -> PlistEntry? in
            if let strVal = entry.value as? String, strVal.hasPrefix("$(") {
                let key = placeholderName(strVal)
                if let val = parameters[key] {
                    return PlistEntry(key: entry.key, value: val)
                }
                return nil
            }
            // Non-placeholder: respect it. But background_modes UIBackgroundModes is declared as
            // a placeholder in the catalog; if a concrete value is passed in parameters, prefer it.
            if let paramVal = parameters[entry.key] {
                return PlistEntry(key: entry.key, value: paramVal)
            }
            return entry
        }
    }

    private static func placeholderName(_ token: String) -> String {
        // "$(AppGroupIdentifier)" → "AppGroupIdentifier"
        var s = token
        if s.hasPrefix("$(") { s.removeFirst(2) }
        if s.hasSuffix(")") { s.removeLast() }
        return s
    }

    // MARK: - Helpers

    private static func findXcodeProj(projectRoot: URL) throws -> URL {
        if projectRoot.pathExtension == "xcodeproj" { return projectRoot }
        let contents = try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let proj = contents.first(where: { $0.pathExtension == "xcodeproj" }) else {
            throw CapabilityApplicatorError.noXcodeProject
        }
        return proj
    }

    private static func appNameFromPbxproj(_ pbx: String) throws -> String {
        // The PRODUCT_NAME or target name. For the template, target name = LatticeTplApp.
        // Find "name = <X>;" inside the PBXNativeTarget application block.
        guard let appRange = pbx.range(of: "productType = \"com.apple.product-type.application\";") else {
            throw CapabilityApplicatorError.noApplicationTarget
        }
        let blockStart = pbx.range(of: "PBXNativeTarget", options: .backwards, range: pbx.startIndex..<appRange.lowerBound)?.lowerBound ?? pbx.startIndex
        let block = pbx[blockStart..<appRange.upperBound]
        if let nameRange = block.range(of: "name = "), let semi = block[nameRange.upperBound...].firstIndex(of: ";") {
            return PbxprojEditor.stripQuotes(String(block[nameRange.upperBound..<semi]).trimmingCharacters(in: .whitespaces))
        }
        return "App"
    }

    private static func extractBuildSettingValue(_ block: String, key: String) -> String? {
        let pattern = "\(key) = ([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: key) + " = ([^;]+);") else { return nil }
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = regex.firstMatch(in: block, range: range), match.numberOfRanges > 1 {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    private static func isEqualPlistValue(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        if let a = a as? [String], let b = b as? [String] { return Set(a) == Set(b) }
        return false
    }
}
```

**Implementer note on the `.appGroups(groupIdentifiers:)` convenience API used in tests:** the tests reference `CapabilityApplicator.apply(capability: .appGroups(groupIdentifiers:), ...)`. But `apply` takes an `AppleCapability`, and `.appGroups(groupIdentifiers:)` is not an `AppleCapability` case. Fix the tests to pass parameters instead:

In the test file, replace:
```swift
CapabilityApplicator.apply(capability: .appGroups(groupIdentifiers: ["group.com.example.app"]), to: fixtureRoot, parameters: [:])
```
with:
```swift
CapabilityApplicator.apply(capabilityId: "app_groups", to: fixtureRoot, parameters: ["AppGroupIdentifier": ["group.com.example.app"]])
```
This uses the real `apply(capabilityId:parameters:)` entry point and exercises placeholder resolution. Apply the same fix to the other `appGroups` tests and the `backgroundModes` test (`parameters: ["UIBackgroundModes": ["audio", "fetch"]]` via `capabilityId: "background_modes"`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS' -only-testing:LatticeTests/CapabilityApplicatorTests`
Expected: PASS — all apply tests pass, including idempotency and unique-merge.

- [ ] **Step 6: Commit**

```bash
git add Lattice/Lattice/CapabilityApplicator.swift Lattice/LatticeTests/CapabilityApplicatorTests.swift Lattice/LatticeTests/Fixtures/MinimalProjectHelper.swift
git commit -m "Add CapabilityApplicator.apply with idempotent entitlement/plist merging"
```

---

## Task 5: Add `CapabilityApplicator.remove`

**Why:** The spec includes `remove_capability`. Remove must strip keys per-capability without breaking others sharing the same file.

**Files:**
- Modify: `Lattice/Lattice/CapabilityApplicator.swift`
- Modify: `Lattice/LatticeTests/CapabilityApplicatorTests.swift`

- [ ] **Step 1: Write failing tests for remove**

Append to `CapabilityApplicatorTests.swift`:

```swift
func testRemoveStripsEntitlementKeys() async throws {
    _ = try await CapabilityApplicator.apply(
        capabilityId: "app_groups",
        to: fixtureRoot,
        parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
    )
    let result = try await CapabilityApplicator.remove(
        capabilityId: "app_groups",
        from: fixtureRoot
    )
    XCTAssertTrue(result.removedKeys.contains("com.apple.security.application-groups"))
    // The entitlements file still exists (never deleted).
    let entFile = result.changedFiles.first { $0.pathExtension == "entitlements" }
    XCTAssertNotNil(entFile)
    let dict = NSDictionary(contentsOf: entFile!) as? [String: Any]
    XCTAssertNil(dict?["com.apple.security.application-groups"])
}

func testRemoveDoesNotDeleteEntitlementsFileWhenOtherKeysRemain() async throws {
    // Apply two capabilities that write to the same entitlements file.
    _ = try await CapabilityApplicator.apply(
        capabilityId: "app_groups",
        to: fixtureRoot,
        parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
    )
    _ = try await CapabilityApplicator.apply(
        capabilityId: "push_notifications",
        to: fixtureRoot,
        parameters: ["APSEnvironment": "development"]
    )
    // Remove only app_groups. aps-environment must survive.
    let result = try await CapabilityApplicator.remove(
        capabilityId: "app_groups",
        from: fixtureRoot
    )
    let entFile = result.changedFiles.first { $0.pathExtension == "entitlements" }!
    let dict = NSDictionary(contentsOf: entFile) as? [String: Any]
    XCTAssertNil(dict?["com.apple.security.application-groups"], "app groups key removed")
    XCTAssertNotNil(dict?["aps-environment"], "push key must survive")
}

func testRemoveIsIdempotent() async throws {
    _ = try await CapabilityApplicator.apply(
        capabilityId: "app_groups",
        to: fixtureRoot,
        parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
    )
    _ = try await CapabilityApplicator.remove(capabilityId: "app_groups", from: fixtureRoot)
    let second = try await CapabilityApplicator.remove(capabilityId: "app_groups", from: fixtureRoot)
    XCTAssertTrue(second.removedKeys.isEmpty, "second remove should report nothing removed")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:LatticeTests/CapabilityApplicatorTests`
Expected: FAIL — `remove` does not exist.

- [ ] **Step 3: Implement `remove`**

Add to `CapabilityApplicator.swift`:

```swift
struct CapabilityRemoveResult {
    let changedFiles: [URL]
    let removedKeys: [String]
    let manualSteps: String?
}

extension CapabilityApplicator {
    static func remove(capabilityId: String, from projectRoot: URL) async throws -> CapabilityRemoveResult {
        guard let cap = AppleCapabilityCatalog.capability(id: capabilityId) else {
            throw CapabilityApplicatorError.unknownCapability(capabilityId)
        }
        var changedFiles: [URL] = []
        var removedKeys: [String] = []

        // 1. Remove entitlement keys (if the capability declares any and a file exists).
        if !cap.entitlements.isEmpty, let entURL = try? findExistingEntitlementsFile(projectRoot: projectRoot) {
            let removed = removeEntitlementKeys(from: entURL, keys: cap.entitlements.map(\.key))
            removedKeys.append(contentsOf: removed.removedKeys)
            if !removed.removedKeys.isEmpty {
                changedFiles.append(entURL)
            }
            // NEVER delete the entitlements file even if empty — other capabilities
            // or the pbxproj CODE_SIGN_ENTITLEMENTS reference may still need it.
        }

        // 2. Remove Info.plist keys owned by this capability.
        if !cap.infoPlistKeys.isEmpty {
            if let plistURL = try? findInfoPlist(projectRoot: projectRoot, pbxText: try String(contentsOf: findXcodeProj(projectRoot: projectRoot).appendingPathComponent("project.pbxproj"), encoding: .utf8)) {
                let removed = removePlistKeys(from: plistURL, keys: cap.infoPlistKeys.map { $0.key })
                removedKeys.append(contentsOf: removed.removedKeys)
                if !removed.removedKeys.isEmpty { changedFiles.append(plistURL) }
            } else {
                // No on-disk Info.plist. Remove INFOPLIST_KEY_<key> build settings from pbxproj.
                let pbxPath = try findXcodeProj(projectRoot: projectRoot).appendingPathComponent("project.pbxproj")
                var text = try String(contentsOf: pbxPath, encoding: .utf8)
                let configIDs = try PbxprojEditor.applicationTargetConfigurationIDs(in: text)
                for key in cap.infoPlistKeys.map(\.key) {
                    for id in configIDs {
                        guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: text) else { continue }
                        var block = String(text[range])
                        let before = block
                        block = removeBuildSetting(block, key: "INFOPLIST_KEY_\(key)")
                        if block != before {
                            text.replaceSubrange(range, with: block)
                            removedKeys.append(key)
                        }
                    }
                }
                if !removedKeys.isEmpty {
                    try text.data(using: .utf8)?.write(to: pbxPath, options: .atomic)
                    changedFiles.append(pbxPath)
                }
            }
        }

        return CapabilityRemoveResult(
            changedFiles: Array(Set(changedFiles)),
            removedKeys: removedKeys,
            manualSteps: cap.provisioningNotes
        )
    }

    private struct KeyRemovalResult {
        let removedKeys: [String]
    }

    private static func findExistingEntitlementsFile(projectRoot: URL) throws -> URL? {
        let pbxPath = try findXcodeProj(projectRoot: projectRoot).appendingPathComponent("project.pbxproj")
        let pbx = try String(contentsOf: pbxPath, encoding: .utf8)
        let configIDs = try PbxprojEditor.applicationTargetConfigurationIDs(in: pbx)
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            if let raw = extractBuildSettingValue(block, key: "CODE_SIGN_ENTITLEMENTS") {
                let path = PbxprojEditor.stripQuotes(raw)
                    .replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
                    .replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private static func removeEntitlementKeys(from url: URL, keys: [String]) -> KeyRemovalResult {
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else {
            return KeyRemovalResult(removedKeys: [])
        }
        var removed: [String] = []
        for key in keys {
            if plist[key] != nil {
                plist.removeObject(forKey: key)
                removed.append(key)
            }
        }
        plist.write(toFile: url.path, atomically: true)
        return KeyRemovalResult(removedKeys: removed)
    }

    private static func removePlistKeys(from url: URL, keys: [String]) -> KeyRemovalResult {
        guard let plist = NSDictionary(contentsOf: url)?.mutableCopy() as? NSMutableDictionary else {
            return KeyRemovalResult(removedKeys: [])
        }
        var removed: [String] = []
        for key in keys {
            if plist[key] != nil {
                plist.removeObject(forKey: key)
                removed.append(key)
            }
        }
        plist.write(toFile: url.path, atomically: true)
        return KeyRemovalResult(removedKeys: removed)
    }

    /// Remove a `key = value;` line from a config block. Returns the block unchanged if not found.
    private static func removeBuildSetting(_ block: String, key: String) -> String {
        let linePattern = "\\n?\\t\\t\\t\\t" + NSRegularExpression.escapedPattern(for: key) + " = [^\\n]*;"
        guard let regex = try? NSRegularExpression(pattern: linePattern, options: []) else { return block }
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: block, options: [], range: range, withTemplate: "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LatticeTests/CapabilityApplicatorTests`
Expected: PASS — all remove tests pass, including the "other keys survive" and idempotency cases.

- [ ] **Step 5: Commit**

```bash
git add Lattice/Lattice/CapabilityApplicator.swift Lattice/LatticeTests/CapabilityApplicatorTests.swift
git commit -m "Add CapabilityApplicator.remove with per-key safe removal"
```

---

## Task 6: Add `CapabilityStatusChecker`

**Why:** The UI needs to show the real state of the project. This read-only module reports which capabilities are active.

**Files:**
- Create: `Lattice/Lattice/CapabilityStatusChecker.swift`
- Create: `Lattice/LatticeTests/CapabilityStatusCheckerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Lattice/LatticeTests/CapabilityStatusCheckerTests.swift`:

```swift
import XCTest
@testable import Lattice

final class CapabilityStatusCheckerTests: XCTestCase {
    var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = try MinimalProjectFixture.make()
    }

    override func tearDownWithError() throws {
        if fixtureRoot != nil { MinimalProjectFixture.tearDown(fixtureRoot) }
    }

    func testNoCapabilitiesActiveByDefault() async throws {
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        XCTAssertTrue(status.activeCapabilities.isEmpty)
    }

    func testDetectsAppGroupsAfterApply() async throws {
        _ = try await CapabilityApplicator.apply(
            capabilityId: "app_groups",
            to: fixtureRoot,
            parameters: ["AppGroupIdentifier": ["group.com.example.app"]]
        )
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        XCTAssertTrue(status.activeCapabilities.contains("app_groups"))
    }

    func testDetectsMultipleCapabilities() async throws {
        _ = try await CapabilityApplicator.apply(capabilityId: "app_groups", to: fixtureRoot, parameters: ["AppGroupIdentifier": ["group.com.example.app"]])
        _ = try await CapabilityApplicator.apply(capabilityId: "storekit", to: fixtureRoot, parameters: [:])
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        XCTAssertTrue(status.activeCapabilities.contains("app_groups"))
        // StoreKit has no entitlements/plist keys — it cannot be detected from files alone.
        // Document this: status checker only detects capabilities with file-side markers.
        XCTAssertFalse(status.activeCapabilities.contains("storekit"))
    }

    func testRemoveClearsStatus() async throws {
        _ = try await CapabilityApplicator.apply(capabilityId: "app_groups", to: fixtureRoot, parameters: ["AppGroupIdentifier": ["group.com.example.app"]])
        _ = try await CapabilityApplicator.remove(capabilityId: "app_groups", from: fixtureRoot)
        let status = try await CapabilityStatusChecker.check(projectRoot: fixtureRoot)
        XCTAssertFalse(status.activeCapabilities.contains("app_groups"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:LatticeTests/CapabilityStatusCheckerTests`
Expected: FAIL — `CapabilityStatusChecker` does not exist.

- [ ] **Step 3: Implement `CapabilityStatusChecker.swift`**

Create `Lattice/Lattice/CapabilityStatusChecker.swift`:

```swift
import Foundation

/// Read-only snapshot of which capabilities are active in a project.
struct CapabilityStatus {
    /// Capability ids whose file-side markers are present.
    let activeCapabilities: Set<String>
}

/// Scans a project's entitlements and Info.plist / build settings to determine
/// which catalog capabilities are currently active. Read-only — never writes.
///
/// Note: capabilities with no file-side markers (e.g. StoreKit, which has only a
/// framework dependency) cannot be detected and will not appear in `activeCapabilities`.
enum CapabilityStatusChecker {
    static func check(projectRoot: URL) async throws -> CapabilityStatus {
        let pbxURL = try findXcodeProj(projectRoot: projectRoot).appendingPathComponent("project.pbxproj")
        let pbx = (try? String(contentsOf: pbxURL, encoding: .utf8)) ?? ""

        // Load entitlements if present.
        let entitlements: [String: Any] = loadEntitlements(projectRoot: projectRoot, pbx: pbx) ?? [:]
        // Load Info.plist if present (on disk).
        let infoPlist: [String: Any] = loadInfoPlist(projectRoot: projectRoot, pbx: pbx) ?? [:]

        var active: Set<String> = []
        for cap in AppleCapabilityCatalog.all {
            if isCapabilityActive(cap, entitlements: entitlements, infoPlist: infoPlist, pbx: pbx) {
                active.insert(cap.id)
            }
        }
        return CapabilityStatus(activeCapabilities: active)
    }

    /// A capability is active if ALL of its file-side markers are present.
    /// For capabilities with no markers (StoreKit), this returns false — undetectable.
    private static func isCapabilityActive(
        _ cap: AppleCapability,
        entitlements: [String: Any],
        infoPlist: [String: Any],
        pbx: String
    ) -> Bool {
        let hasMarkers = !cap.entitlements.isEmpty || !cap.infoPlistKeys.isEmpty
        guard hasMarkers else { return false }

        // All entitlement keys present?
        let allEntitlementsPresent = cap.entitlements.allSatisfy { entry in
            entitlements[entry.key] != nil
        }
        // All plist keys present?
        let allPlistPresent = cap.infoPlistKeys.allSatisfy { entry in
            if infoPlist[entry.key] != nil { return true }
            // Check INFOPLIST_KEY_<key> build setting too.
            return pbx.contains("INFOPLIST_KEY_\(entry.key)")
        }
        return allEntitlementsPresent && allPlistPresent
    }

    private static func loadEntitlements(projectRoot: URL, pbx: String) -> [String: Any]? {
        guard let configIDs = try? PbxprojEditor.applicationTargetConfigurationIDs(in: pbx) else { return nil }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            if let raw = extractValue(block, key: "CODE_SIGN_ENTITLEMENTS") {
                var path = PbxprojEditor.stripQuotes(raw)
                path = path.replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
                path = path.replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path)
                if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                    return dict
                }
            }
        }
        return nil
    }

    private static func loadInfoPlist(projectRoot: URL, pbx: String) -> [String: Any]? {
        guard let configIDs = try? PbxprojEditor.applicationTargetConfigurationIDs(in: pbx) else { return nil }
        for id in configIDs {
            guard let range = PbxprojEditor.blockRange(forConfigurationID: id, in: pbx) else { continue }
            let block = String(pbx[range])
            if let raw = extractValue(block, key: "INFOPLIST_FILE") {
                var path = PbxprojEditor.stripQuotes(raw)
                path = path.replacingOccurrences(of: "$(SRCROOT)", with: projectRoot.path)
                path = path.replacingOccurrences(of: "${SRCROOT}", with: projectRoot.path)
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path)
                if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                    return dict
                }
            }
        }
        return nil
    }

    private static func extractValue(_ block: String, key: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: key) + " = ([^;]+);") else { return nil }
        let ns = block as NSString
        if let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    private static func findXcodeProj(projectRoot: URL) throws -> URL {
        if projectRoot.pathExtension == "xcodeproj" { return projectRoot }
        let contents = try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let proj = contents.first(where: { $0.pathExtension == "xcodeproj" }) else {
            throw CapabilityApplicatorError.noXcodeProject
        }
        return proj
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LatticeTests/CapabilityStatusCheckerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lattice/Lattice/CapabilityStatusChecker.swift Lattice/LatticeTests/CapabilityStatusCheckerTests.swift
git commit -m "Add CapabilityStatusChecker for read-only project state detection"
```

---

## Task 7: Wire `add_capability` / `remove_capability` tools into `ToolExecutor`

**Why:** Now the LLM can use the engine instead of hand-writing entitlements.

**Files:**
- Modify: `Lattice/Lattice/ToolExecutor.swift`
- Modify: `Lattice/Lattice/ContentView.swift` (pass project root to executor)

- [ ] **Step 1: Make `ToolExecutor` accept a project root**

The executor is currently stateless and resolves bash cwd from `FileManager.default.currentDirectoryPath`. Add an optional project root that capability tools use. In `ToolExecutor.swift`:

```swift
struct ToolExecutor {
    /// Project root path, passed in by the chat view so capability tools resolve
    /// the correct Xcode project. nil = not available (capability tools will error).
    var projectRootPath: String?

    init(projectRootPath: String? = nil) {
        self.projectRootPath = projectRootPath
    }

    func execute(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        switch name {
        // ... existing cases unchanged ...

        case "add_capability":
            return await handleAddCapability(input: input)
        case "remove_capability":
            return await handleRemoveCapability(input: input)

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    // ... existing private methods ...
```

- [ ] **Step 2: Implement the tool handlers**

Add to `ToolExecutor.swift`:

```swift
    private func handleAddCapability(input: [String: Any]) async -> (String, Bool) {
        guard let capabilityId = input["capability"] as? String else {
            return ("Missing 'capability' parameter", true)
        }
        guard let projectRootPath, !projectRootPath.isEmpty else {
            return ("No project folder is open. Open a project before adding a capability.", true)
        }
        let parameters = (input["parameters"] as? [String: Any]) ?? [:]
        do {
            let result = try await CapabilityApplicator.apply(
                capabilityId: capabilityId,
                to: URL(fileURLWithPath: projectRootPath),
                parameters: parameters
            )
            var summary = "Added \(capabilityId)."
            if !result.changedFiles.isEmpty {
                summary += " Updated: " + result.changedFiles.map(\.lastPathComponent).joined(separator: ", ") + "."
            }
            if !result.alreadyPresent.isEmpty {
                summary += " Already present: " + result.alreadyPresent.joined(separator: ", ") + "."
            }
            if let steps = result.manualSteps {
                summary += "\n\nManual steps required:\n\(steps)"
            }
            return (summary, false)
        } catch let err as CapabilityApplicatorError {
            return (err.localizedDescription, true)
        } catch {
            return ("Failed to add capability: \(error.localizedDescription)", true)
        }
    }

    private func handleRemoveCapability(input: [String: Any]) async -> (String, Bool) {
        guard let capabilityId = input["capability"] as? String else {
            return ("Missing 'capability' parameter", true)
        }
        guard let projectRootPath, !projectRootPath.isEmpty else {
            return ("No project folder is open.", true)
        }
        do {
            let result = try await CapabilityApplicator.remove(
                capabilityId: capabilityId,
                from: URL(fileURLWithPath: projectRootPath)
            )
            if result.removedKeys.isEmpty {
                return ("\(capabilityId) was not present; nothing removed.", false)
            }
            var summary = "Removed \(capabilityId). Stripped: " + result.removedKeys.joined(separator: ", ") + "."
            if let steps = result.manualSteps {
                summary += "\n\nNote: \(steps)"
            }
            return (summary, false)
        } catch let err as CapabilityApplicatorError {
            return (err.localizedDescription, true)
        } catch {
            return ("Failed to remove capability: \(error.localizedDescription)", true)
        }
    }
```

- [ ] **Step 3: Update the call site in `ContentView.swift`**

At `ContentView.swift:557`, change:

```swift
private let executor = ToolExecutor()
```

to a computed/lazy property that reflects the current project. Since `scopedProjectPath` is the source of truth, use:

```swift
private var executor: ToolExecutor {
    ToolExecutor(projectRootPath: scopedProjectPath.isEmpty ? nil : scopedProjectPath)
}
```

Remove the `private let executor = ToolExecutor()` line. Verify the call site at line 1256 (`await executor.execute(...)`) still compiles — it will, since `executor` is now a computed `var`.

- [ ] **Step 4: Run the app to verify it builds**

Run: `xcodebuild build -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Lattice/Lattice/ToolExecutor.swift Lattice/Lattice/ContentView.swift
git commit -m "Wire add_capability and remove_capability tools into ToolExecutor"
```

---

## Task 8: Register tools + rewrite the capability system prompt in `LLMService`

**Why:** The LLM needs to know the tools exist and be told to use them instead of hand-editing entitlements.

**Files:**
- Modify: `Lattice/Lattice/LLMService.swift`

- [ ] **Step 1: Add tool definitions**

At `LLMService.swift:150` (`latticeToolDefinitions`), append the two new tools before the closing `]`:

```swift
        [
            "name": "add_capability",
            "description": "Add an Apple capability to the current project. Updates entitlements, Info.plist, and project build settings correctly and idempotently. Always use this instead of hand-editing entitlements or project.pbxproj for capabilities.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "enum": ["app_groups", "push_notifications", "storekit", "keychain_sharing", "background_modes"],
                        "description": "The capability to add."
                    ],
                    "parameters": [
                        "type": "object",
                        "description": "Capability-specific values. app_groups: AppGroupIdentifier (array of group ids). push_notifications: APSEnvironment ('development' or 'production'). background_modes: UIBackgroundModes (array, e.g. ['audio','remote-notification']). keychain_sharing: KeychainAccessGroup (string). storekit: none.",
                        "properties": [:]
                    ]
                ],
                "required": ["capability"]
            ]
        ],
        [
            "name": "remove_capability",
            "description": "Remove an Apple capability from the current project. Strips the capability's entitlement and Info.plist keys safely without affecting other capabilities.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "enum": ["app_groups", "push_notifications", "storekit", "keychain_sharing", "background_modes"],
                        "description": "The capability to remove."
                    ]
                ],
                "required": ["capability"]
            ]
        ]
```

- [ ] **Step 2: Rewrite the capability system prompt lines**

At `LLMService.swift:749-753`, replace these five lines:

```
        - When the user asks for Apple capabilities or a feature that requires them, you may update the project files needed to support it: entitlements, Info.plist keys, project build settings, and file references in the Xcode project. Do the file-side work yourself when possible.
        - Capability examples include push notifications, background modes, associated domains, app groups, HealthKit, camera, microphone, photo library, and local network access.
        - If a capability also needs an Apple Developer portal action or manual Xcode signing step, still do the file-side changes and then tell the user exactly what remains to be enabled manually.
        - If a valid Xcode project already exists, edit that project in place. Do not invent a second app scaffold or hand-roll a fresh project structure beside it.
        - Do not hand-write or replace project.pbxproj just to scaffold a new app when a Lattice template project already exists. Prefer editing the source files, plist, entitlements, and asset catalog inside the existing project.
```

with:

```
        - When the user asks for an Apple capability, use the add_capability tool. Supported capabilities: app_groups, push_notifications, storekit, keychain_sharing, background_modes. The tool handles entitlements, Info.plist keys, and project build settings correctly and idempotently.
        - Never hand-write or hand-edit .entitlements files or entitlement-related project.pbxproj entries. Always use add_capability / remove_capability instead.
        - For capabilities outside the supported list (HealthKit, Associated Domains, iCloud, etc.), use the web_search tool to find the correct entitlement and plist keys, then explain to the user what manual steps are needed. Do not hand-write entitlements for unsupported capabilities.
        - After add_capability returns manual steps, relay them to the user verbatim so they can complete provisioning in the Apple Developer Portal or Xcode.
        - If a valid Xcode project already exists, edit that project in place. Do not invent a second app scaffold or hand-roll a fresh project structure beside it.
        - Do not hand-write or replace project.pbxproj just to scaffold a new app when a Lattice template project already exists. Prefer editing the source files, plist, entitlements, and asset catalog inside the existing project.
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lattice/Lattice/LLMService.swift
git commit -m "Register capability tools and rewrite capability system prompt"
```

---

## Task 9: Build the `CapabilitySettingsView` UI

**Why:** Users should be able to toggle capabilities visually, driven by the same engine.

**Files:**
- Create: `Lattice/Lattice/CapabilitySettingsView.swift`
- Modify: `Lattice/Lattice/ContentView.swift` (add a Section)

- [ ] **Step 1: Implement `CapabilitySettingsView.swift`**

Create `Lattice/Lattice/CapabilitySettingsView.swift`:

```swift
import SwiftUI

/// A section for browsing and toggling Apple capabilities.
/// Shares the same `CapabilityApplicator` engine as the chat tools.
struct CapabilitySettingsView: View {
    let projectRoot: URL

    @State private var status: CapabilityStatus?
    @State private var pendingCapabilityId: String?
    @State private var errorText: String?
    @State private var showingParameters: String?

    // Per-capability parameter inputs.
    @State private var appGroupInput: String = ""
    @State private var apsEnvironment: String = "development"
    @State private var keychainGroupInput: String = ""
    @State private var backgroundModesInput: Set<String> = []

    var body: some View {
        ForEach(AppleCapabilityCatalog.all) { cap in
            capabilityRow(cap)
        }
        if let err = errorText {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func capabilityRow(_ cap: AppleCapability) -> some View {
        let isActive = status?.activeCapabilities.contains(cap.id) ?? false
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { isActive },
                set: { newValue in handleToggle(cap, isOn: newValue) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap.displayName).font(.body)
                    Text(cap.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if cap.id == showingParameters {
                parameterEditor(for: cap)
            }
            if let notes = cap.provisioningNotes, isActive {
                DisclosureGroup("Manual steps") {
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func parameterEditor(for cap: AppleCapability) -> some View {
        switch cap.id {
        case "app_groups":
            TextField("App group identifier, e.g. group.com.example.app", text: $appGroupInput)
                .textFieldStyle(.roundedBorder)
        case "push_notifications":
            Picker("APNs environment", selection: $apsEnvironment) {
                Text("Development").tag("development")
                Text("Production").tag("production")
            }
            .pickerStyle(.segmented)
        case "keychain_sharing":
            TextField("Keychain access group, e.g. $(AppIdentifierPrefix)com.example.shared", text: $keychainGroupInput)
                .textFieldStyle(.roundedBorder)
        case "background_modes":
            VStack(alignment: .leading) {
                ForEach(["audio", "fetch", "processing", "remote-notification"], id: \.self) { mode in
                    Toggle(mode, isOn: Binding(
                        get: { backgroundModesInput.contains(mode) },
                        set: { if $0 { backgroundModesInput.insert(mode) } else { backgroundModesInput.remove(mode) } }
                    ))
                }
            }
        default:
            EmptyView()
        }
    }

    private func handleToggle(_ cap: AppleCapability, isOn: Bool) {
        if isOn {
            // If the capability needs parameters, show the editor first; apply on a second toggle.
            if needsParameters(cap) && showingParameters != cap.id {
                showingParameters = cap.id
                return
            }
            Task { await applyCapability(cap) }
        } else {
            Task { await removeCapability(cap) }
        }
    }

    private func needsParameters(_ cap: AppleCapability) -> Bool {
        switch cap.id {
        case "app_groups", "push_notifications", "keychain_sharing", "background_modes":
            return true
        default:
            return false
        }
    }

    private func parameters(for cap: AppleCapability) -> [String: Any] {
        switch cap.id {
        case "app_groups":
            let ids = appGroupInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ["AppGroupIdentifier": ids]
        case "push_notifications":
            return ["APSEnvironment": apsEnvironment]
        case "keychain_sharing":
            return ["KeychainAccessGroup": keychainGroupInput]
        case "background_modes":
            return ["UIBackgroundModes": Array(backgroundModesInput)]
        default:
            return [:]
        }
    }

    private func applyCapability(_ cap: AppleCapability) async {
        pendingCapabilityId = cap.id
        errorText = nil
        do {
            _ = try await CapabilityApplicator.apply(
                capabilityId: cap.id,
                to: projectRoot,
                parameters: parameters(for: cap)
            )
            showingParameters = nil
            await refreshStatus()
        } catch {
            errorText = error.localizedDescription
        }
        pendingCapabilityId = nil
    }

    private func removeCapability(_ cap: AppleCapability) async {
        pendingCapabilityId = cap.id
        errorText = nil
        do {
            _ = try await CapabilityApplicator.remove(capabilityId: cap.id, from: projectRoot)
            await refreshStatus()
        } catch {
            errorText = error.localizedDescription
        }
        pendingCapabilityId = nil
    }

    private func refreshStatus() async {
        do {
            status = try await CapabilityStatusChecker.check(projectRoot: projectRoot)
        } catch {
            status = CapabilityStatus(activeCapabilities: [])
        }
    }

    func refresh() {
        Task { await refreshStatus() }
    }
}
```

- [ ] **Step 2: Add the section to `ContentView.swift`**

Near `ContentView.swift:6609` (after the App identity section footer, before the Signing section), insert:

```swift
            Section {
                if let root = currentProjectRootURL {
                    CapabilitySettingsView(projectRoot: root)
                } else {
                    Text("Open a project to manage capabilities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Capabilities")
            } footer: {
                Text("Add Apple capabilities with correct entitlements and project settings. Some capabilities require manual steps in the Apple Developer Portal.")
            }
```

You'll need a computed property for the project root URL. Add near `scopedProjectPath`:

```swift
private var currentProjectRootURL: URL? {
    let path = scopedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lattice/Lattice/CapabilitySettingsView.swift Lattice/Lattice/ContentView.swift
git commit -m "Add CapabilitySettingsView with toggle UI in Identity editor"
```

---

## Task 10: Refresh capability UI state after chat tool calls

**Why:** When the LLM adds a capability via chat, the UI must update to reflect reality. (Spec acceptance criterion #5.)

**Files:**
- Modify: `Lattice/Lattice/ContentView.swift`

- [ ] **Step 1: Find where tool execution completes**

At `ContentView.swift:1256-1275`, the loop calls `executor.execute` and updates `items[itemsIdx]`. After a successful tool execution, if the tool was `add_capability` or `remove_capability`, trigger a status refresh.

- [ ] **Step 2: Add a refresh hook**

After the `items[itemsIdx].setToolResult(...)` line (around 1274), add:

```swift
                if toolName == "add_capability" || toolName == "remove_capability" {
                    capabilityRefreshTrigger += 1
                }
```

Add state near `scopedProjectPath`:

```swift
@State private var capabilityRefreshTrigger: Int = 0
```

Then, where the Identity editor sheet is built (find the `CapabilitySettingsView` usage), pass a refresh trigger via `.onChange(of: capabilityRefreshTrigger)`:

```swift
CapabilitySettingsView(projectRoot: root)
    .onChange(of: capabilityRefreshTrigger) { _, _ in
        // The view's refresh() is called via .task(id:) — or call directly.
    }
```

A cleaner approach: make `CapabilitySettingsView` observe an external trigger. Change its body to use `.task(id: refreshToken)`:

```swift
struct CapabilitySettingsView: View {
    let projectRoot: URL
    var refreshToken: Int = 0
    // ...
    var body: some View {
        ForEach(...) { ... }
        .task(id: refreshToken) {
            await refreshStatus()
        }
    }
}
```

Pass `refreshToken: capabilityRefreshTrigger` from ContentView.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lattice/Lattice/ContentView.swift Lattice/Lattice/CapabilitySettingsView.swift
git commit -m "Refresh capability UI after chat add/remove tool calls"
```

---

## Task 11: End-to-end manual verification + README update

**Why:** Verify the full flow works and update docs to match reality.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project Lattice/Lattice.xcodeproj -scheme Lattice -destination 'platform=macOS'`
Expected: All tests pass.

- [ ] **Step 2: Manual verification via the app**

Launch Lattice (`Cmd+R`). Create a new iOS project from the hub. Open the Identity editor → Capabilities section. Toggle on Background Modes, select "audio", verify it applies. Then via chat, ask the LLM "add push notifications in development". Confirm the tool is called and the UI updates. Toggle off App Groups and confirm the entitlement key is removed.

- [ ] **Step 3: Update the README**

Replace the line at `README.md:41`:

```
- Lattice supports adding Capabilities to your app such as Shared App Groups or MusicKit
```

with:

```
- Structured Apple capability support via a dedicated engine: add App Groups, Push Notifications, StoreKit, Keychain Sharing, and Background Modes with correct, idempotent entitlements and project settings — through chat or the Capabilities section in the Identity editor
```

Also update `README.md:94-95` (the "Things still improving" list) to remove capability setup from the TODO, since it's now implemented.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Update README to reflect structured capability support"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- ✅ Catalog (5 caps) → Task 3
- ✅ Applicator.apply → Task 4, .remove → Task 5
- ✅ StatusChecker → Task 6
- ✅ PbxprojEditor shared + extracted → Tasks 1–2
- ✅ add/remove tools → Task 7
- ✅ System prompt rewrite → Task 8
- ✅ CapabilitySettingsView → Task 9
- ✅ Chat→UI refresh → Task 10
- ✅ Idempotency → tested in Tasks 2, 4, 5
- ✅ ContentView grows by one Section only → Task 9 Step 2
- ✅ README → Task 11

**Placeholder scan:** The `MinimalProjectHelper.swift` Step 1 contains a broken `#"\#${SRCROOT}"#` line that the note immediately after tells the implementer to remove — flagged explicitly. All other code blocks are complete.

**Type consistency:** `CapabilityApplyResult`, `CapabilityRemoveResult`, `CapabilityStatus`, `EntitlementWiringResult`, `CapabilityApplicatorError`, `ApplePlatform` — names are consistent across tasks. `PbxprojEditor.ensureEntitlementsFileReference` signature matches its tests. `apply(capabilityId:parameters:)` is the canonical entry point; tests that used `.appGroups(groupIdentifiers:)` are flagged with an explicit fix in Task 4 Step 4.

**Known risk for implementer:** Swift substring index arithmetic in `addToBuildPhaseFiles`/`addToGroupChildren` (Task 2 Step 3) — the plan includes a corrected pattern and a `plutil -lint` test to catch breakage. The `findSourceGroupID` heuristic is brittle; if it fails, the plutil test will catch it and the implementer should fall back to locating the group by parsing the `PBXGroup` that contains a known `.swift` file ref.

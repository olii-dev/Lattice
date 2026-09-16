import Testing
import Foundation
@testable import Lattice

@Suite struct UnifiedDiffTests {

    @Test func identicalContentProducesEmptyDiff() {
        let result = UnifiedDiff.generate(old: "a\nb\nc", new: "a\nb\nc")
        #expect(result.lines.isEmpty)
        #expect(result.addedCount == 0)
        #expect(result.removedCount == 0)
        #expect(!result.isTruncated)
    }

    @Test func additionIsMarkedWithNumbers() {
        let result = UnifiedDiff.generate(old: "a\nb", new: "a\nb\nc")
        #expect(result.addedCount == 1)
        #expect(result.removedCount == 0)
        let added = result.lines.filter { $0.kind == .added }
        #expect(added.count == 1)
        #expect(added[0].text == "c")
        #expect(added[0].newNumber == 3)
        #expect(added[0].oldNumber == nil)
    }

    @Test func replacementShowsRemovedThenAdded() {
        let result = UnifiedDiff.generate(old: "old line\nkeep", new: "new line\nkeep")
        let changed = result.lines.filter { $0.kind != .same }
        #expect(changed.count == 2)
        #expect(changed[0].kind == .removed)
        #expect(changed[0].text == "old line")
        #expect(changed[1].kind == .added)
        #expect(changed[1].text == "new line")
    }

    @Test func deletionIsMarked() {
        let result = UnifiedDiff.generate(old: "a\nb\nc", new: "a\nc")
        #expect(result.removedCount == 1)
        let removed = result.lines.filter { $0.kind == .removed }
        #expect(removed.count == 1)
        #expect(removed[0].text == "b")
        #expect(removed[0].oldNumber == 2)
        #expect(removed[0].newNumber == nil)
    }

    @Test func longUnchangedRunsCollapseWithContext() {
        let filler = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let old = "change here\n" + filler
        let new = "changed there\n" + filler
        let result = UnifiedDiff.generate(old: old, new: new)
        #expect(result.isTruncated)
        #expect(result.omittedCount > 0)
        #expect(result.lines.count < 30)
        #expect(result.lines.contains { $0.text.contains("unchanged lines") })
        // Changed lines survive the collapse.
        #expect(result.lines.contains { $0.kind == .removed && $0.text == "change here" })
        #expect(result.lines.contains { $0.kind == .added && $0.text == "changed there" })
    }

    @Test func veryLargeFilesAreSummarized() {
        let old = Array(repeating: "x", count: 6_000).joined(separator: "\n")
        let new = Array(repeating: "y", count: 6_000).joined(separator: "\n")
        let result = UnifiedDiff.generate(old: old, new: new)
        #expect(result.isTruncated)
        #expect(result.addedCount == 6_000)
        #expect(result.removedCount == 6_000)
        #expect(result.lines.count <= 4)
    }

    @Test func emptyToContentIsPureAddition() {
        let result = UnifiedDiff.generate(old: "", new: "hello\nworld")
        #expect(result.addedCount == 2)
        #expect(result.removedCount == 1) // trailing empty line in old ""
        let addedTexts = result.lines.filter { $0.kind == .added }.map(\.text)
        #expect(addedTexts.contains("hello"))
        #expect(addedTexts.contains("world"))
    }
}

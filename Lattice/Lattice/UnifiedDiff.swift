import Foundation

/// Line-based unified diff used by the write-approval card. Pure logic, no I/O.
enum UnifiedDiff {

    struct Line: Equatable {
        enum Kind: Equatable {
            case same
            case added
            case removed
        }

        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    struct Result: Equatable {
        let lines: [Line]
        /// Lines omitted from the middle for very large changes (nil when complete).
        let omittedCount: Int
        let addedCount: Int
        let removedCount: Int

        var isTruncated: Bool { omittedCount > 0 }
    }

    /// Both sides beyond this line count are summarized instead of diffed.
    private static let maxDiffableLines = 5_000
    /// Cap on emitted diff lines before the middle is elided.
    private static let maxRenderedLines = 400

    /// Generates a line diff between `old` and `new` (LCS-based).
    static func generate(old: String, new: String) -> Result {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard oldLines != newLines else {
            return Result(lines: [], omittedCount: 0, addedCount: 0, removedCount: 0)
        }

        if oldLines.count > maxDiffableLines || newLines.count > maxDiffableLines {
            return Result(
                lines: [
                    Line(kind: .removed, text: "— previous file (\(oldLines.count) lines)", oldNumber: nil, newNumber: nil),
                    Line(kind: .added, text: "+ new file (\(newLines.count) lines)", oldNumber: nil, newNumber: nil),
                ],
                omittedCount: max(0, oldLines.count + newLines.count - 2),
                addedCount: newLines.count,
                removedCount: oldLines.count
            )
        }

        let ops = longestCommonSubsequenceOperations(old: oldLines, new: newLines)

        var numbered: [Line] = []
        var oldNumber = 0
        var newNumber = 0
        var added = 0
        var removed = 0
        for op in ops {
            switch op {
            case .same(let index):
                oldNumber += 1
                newNumber += 1
                numbered.append(Line(kind: .same, text: oldLines[index], oldNumber: oldNumber, newNumber: newNumber))
            case .removed(let index):
                oldNumber += 1
                removed += 1
                numbered.append(Line(kind: .removed, text: oldLines[index], oldNumber: oldNumber, newNumber: nil))
            case .added(let index):
                newNumber += 1
                added += 1
                numbered.append(Line(kind: .added, text: newLines[index], oldNumber: nil, newNumber: newNumber))
            }
        }

        let (rendered, omitted) = collapseUnchanged(numbered, contextLines: 3)
        return Result(lines: rendered, omittedCount: omitted, addedCount: added, removedCount: removed)
    }

    private enum Operation {
        case same(Int)   // index into old lines
        case removed(Int)
        case added(Int)
    }

    /// Classic LCS backtrack producing an ordered op list.
    private static func longestCommonSubsequenceOperations(old: [String], new: [String]) -> [Operation] {
        let m = old.count
        let n = new.count
        // lcs[i][j] = LCS length of old[i...] and new[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var ops: [Operation] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if old[i] == new[j] {
                ops.append(.same(i))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.removed(i))
                i += 1
            } else {
                ops.append(.added(j))
                j += 1
            }
        }
        while i < m {
            ops.append(.removed(i))
            i += 1
        }
        while j < n {
            ops.append(.added(j))
            j += 1
        }
        return ops
    }

    /// Collapses runs of unchanged lines longer than 2×context into elided middles,
    /// keeping `contextLines` around each change.
    private static func collapseUnchanged(_ lines: [Line], contextLines: Int) -> ([Line], Int) {
        let changeIndexes = lines.enumerated().filter { $0.element.kind != .same }.map(\.offset)
        guard !changeIndexes.isEmpty else {
            return (lines, 0)
        }

        var keep = Array(repeating: false, count: lines.count)
        for index in changeIndexes {
            let low = max(0, index - contextLines)
            let high = min(lines.count - 1, index + contextLines)
            for k in low...high { keep[k] = true }
        }

        var rendered: [Line] = []
        var omittedTotal = 0
        var runStart: Int? = nil
        for (index, line) in lines.enumerated() {
            if keep[index] {
                if let start = runStart {
                    omittedTotal += index - start
                    if omittedTotalWasSignificant(index - start) {
                        rendered.append(
                            Line(kind: .same, text: "… \(index - start) unchanged lines …", oldNumber: nil, newNumber: nil)
                        )
                    }
                    runStart = nil
                }
                rendered.append(line)
            } else if runStart == nil {
                runStart = index
            }
        }
        if let start = runStart {
            let count = lines.count - start
            omittedTotal += count
            rendered.append(Line(kind: .same, text: "… \(count) unchanged lines …", oldNumber: nil, newNumber: nil))
        }
        return (rendered, omittedTotal)
    }

    private static func omittedTotalWasSignificant(_ count: Int) -> Bool {
        count > 0
    }
}

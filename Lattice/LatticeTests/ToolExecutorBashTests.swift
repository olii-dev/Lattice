import Testing
import Foundation
@testable import Lattice

@Suite struct ToolExecutorBashTests {

    @Test func runsInProjectRootWhenAvailable() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-bash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let executor = ToolExecutor(projectRootPath: dir.path)
        let (output, isError) = await executor.execute(name: "bash", input: ["command": "pwd"])

        #expect(!isError)
        let reported = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().path
        let expected = dir.resolvingSymlinksInPath().path
        #expect(reported == expected)
    }

    @Test func fallsBackToTempDirectoryWithoutProjectRoot() async {
        let executor = ToolExecutor(projectRootPath: nil)
        let (output, isError) = await executor.execute(name: "bash", input: ["command": "pwd"])

        #expect(!isError)
        let reported = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().path
        #expect(reported.hasPrefix(temp))
    }

    @Test func largeOutputCompletesWithoutDeadlock() async throws {
        // ~1.9MB of stdout, far beyond the 64KB OS pipe buffer that deadlocked the
        // previous sequential-read implementation.
        let executor = ToolExecutor(projectRootPath: nil)
        let (output, isError) = await executor.execute(
            name: "bash",
            input: ["command": "for i in $(seq 1 150000); do echo \"line-$i\"; done"]
        )

        #expect(!isError)
        #expect(output.contains("line-1"))
        #expect(output.contains("line-150000"))
    }

    @Test func capturesStderrAndExitStatus() async {
        let executor = ToolExecutor(projectRootPath: nil)
        let (output, isError) = await executor.execute(
            name: "bash",
            input: ["command": "echo oops >&2; exit 3"]
        )

        #expect(isError)
        #expect(output.contains("oops"))
    }

    @Test func truncatesOversizedOutput() async {
        let executor = ToolExecutor(projectRootPath: nil)
        let (output, _) = await executor.execute(
            name: "bash",
            input: ["command": "yes lattice-pad | head -c 800000"]
        )

        #expect(output.count < 800_000)
        #expect(output.contains("[output truncated"))
    }
}

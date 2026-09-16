import Testing
import Foundation
@testable import Lattice

@Suite struct LatticeGitWorkspaceCheckpointTests {

    /// Creates a temp dir initialized as a git repo with one commit on `main`.
    private static func makeGitRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-gitckpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(in: dir, ["init", "-b", "main"])
        try runGit(in: dir, ["config", "user.email", "tests@lattice.local"])
        try runGit(in: dir, ["config", "user.name", "Lattice Tests"])
        try "baseline\n".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: dir, ["add", "."])
        try runGit(in: dir, ["commit", "-m", "baseline"])
        return dir
    }

    private static func runGit(in dir: URL, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = arguments
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "GitCheckpointTests", code: Int(p.terminationStatus))
        }
    }

    private static func gitOutput(in dir: URL, _ arguments: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = arguments
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readTrackedFile(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("tracked.txt"), encoding: .utf8)) ?? ""
    }

    @Test func restoreRollsBackCommittedAndUntrackedChanges() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let baselineOID = LatticeGitWorkspaceCheckpoint.captureHead(worktree: repo.path)
        #expect(baselineOID != nil)

        // Simulate an agent turn: modify tracked file and drop in untracked junk.
        try "agent edits\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "junk\n".write(to: repo.appendingPathComponent("untracked.tmp"), atomically: true, encoding: .utf8)

        let result = LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: repo.path, revision: baselineOID!)
        #expect(result.isSuccess, "\(result.failureDetail ?? "")")

        #expect(Self.readTrackedFile(repo) == "baseline\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("untracked.tmp").path))
    }

    @Test func refusesToDestroyWorktreeWhenRevisionMissing() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Simulate a silently failed snapshot capture: OID that never existed.
        try "precious local work\n".write(
            to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )
        try "untracked\n".write(to: repo.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let result = LatticeGitWorkspaceCheckpoint.resetHardAndClean(
            worktree: repo.path,
            revision: String(repeating: "a", count: 40)
        )
        #expect(!result.isSuccess)

        // The working tree must be untouched.
        #expect(Self.readTrackedFile(repo) == "precious local work\n")
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("notes.md").path))
        let status = Self.gitOutput(in: repo, ["status", "--porcelain"])
        #expect(status.contains("M tracked.txt"))
        #expect(status.contains("notes.md"))
    }

    @Test func rejectsNonGitDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = LatticeGitWorkspaceCheckpoint.resetHardAndClean(worktree: dir.path, revision: "HEAD")
        #expect(!result.isSuccess)
    }

    @Test func captureSnapshotFallsBackToHeadWhenStashUnsupported() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let snap = LatticeGitWorkspaceCheckpoint.captureWorkingTreeSnapshot(worktree: repo.path)
        let head = LatticeGitWorkspaceCheckpoint.captureHead(worktree: repo.path)
        #expect(snap != nil)
        #expect(snap == head)
    }
}

import Testing
import Foundation
@testable import Lattice

@Suite struct SourceControlServiceTests {

    private static func makeGitRepo(withRemote remoteURL: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(in: dir, ["init", "-b", "main"])
        try runGit(in: dir, ["config", "user.email", "tests@lattice.local"])
        try runGit(in: dir, ["config", "user.name", "Lattice Tests"])
        if let remoteURL {
            try runGit(in: dir, ["remote", "add", "origin", remoteURL])
        }
        try "hello\n".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(in: dir, ["add", "-A"])
        try runGit(in: dir, ["commit", "-m", "initial"])
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
            throw NSError(domain: "SourceControlTests", code: Int(p.terminationStatus))
        }
    }

    private static func nonRepoDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-noscm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Status

    @Test func statusReportsCleanAfterCommit() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let status = SourceControlService.status(projectRoot: repo)
        #expect(status.isRepository)
        #expect(status.branch == "main")
        #expect(status.dirtyCount == 0)
        #expect(status.untrackedCount == 0)
    }

    @Test func statusCountsDirtyAndUntrackedFiles() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "changed\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        let status = SourceControlService.status(projectRoot: repo)
        #expect(status.dirtyCount == 1)
        #expect(status.untrackedCount == 1)
    }

    @Test func statusHandlesNonRepository() async throws {
        let dir = try Self.nonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let status = SourceControlService.status(projectRoot: dir)
        #expect(!status.isRepository)
        #expect(status.branch == nil)
    }

    @Test func parseStatusReadsAheadBehindAndUpstream() {
        let sample = """
        # branch.oid 1234567890abcdef
        # branch.head feature/login
        # branch.upstream origin/feature/login
        # branch.ab +2 -1
        1 .M N... app.swift
        ? notes.md
        """
        let status = SourceControlService.parseStatus(sample)
        #expect(status.branch == "feature/login")
        #expect(status.hasUpstream)
        #expect(status.aheadCount == 2)
        #expect(status.behindCount == 1)
        #expect(status.dirtyCount == 1)
        #expect(status.untrackedCount == 1)
    }

    // MARK: - Commit + init

    @Test func commitStagesAndCommitsChanges() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "updated\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try SourceControlService.commit(projectRoot: repo, message: "update file")

        let status = SourceControlService.status(projectRoot: repo)
        #expect(status.dirtyCount == 0)
        #expect(status.untrackedCount == 0)
    }

    @Test func initializeRepositoryCreatesRepoWithCommit() async throws {
        let dir = try Self.nonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "app\n".write(to: dir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        try SourceControlService.initializeRepository(projectRoot: dir)

        let status = SourceControlService.status(projectRoot: dir)
        #expect(status.isRepository)
        #expect(status.branch == "main")
        #expect(status.dirtyCount == 0)
        // Re-init is a no-op, not an error.
        try SourceControlService.initializeRepository(projectRoot: dir)
    }

    // MARK: - Remote + PR URL

    @Test func ownerRepoParsesHTTPSAndSSHRemotes() {
        func parsed(_ url: String) -> String? {
            guard let r = SourceControlService.ownerRepo(fromRemoteURL: url) else { return nil }
            return "\(r.owner)/\(r.repo)"
        }
        #expect(parsed("https://github.com/olii-dev/Lattice.git") == "olii-dev/Lattice")
        #expect(parsed("https://github.com/olii-dev/Lattice") == "olii-dev/Lattice")
        #expect(parsed("git@github.com:olii-dev/Lattice.git") == "olii-dev/Lattice")
        #expect(parsed("ssh://git@github.com/olii-dev/Lattice.git") == "olii-dev/Lattice")
        #expect(parsed("https://gitlab.com/a/b.git") == nil)
        #expect(parsed("") == nil)
    }

    @Test func pullRequestURLBuildsFromGitHubRemote() async throws {
        let repo = try Self.makeGitRepo(withRemote: "https://github.com/olii-dev/DemoApp.git")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.runGit(in: repo, ["checkout", "-b", "feature/cool"])

        let url = SourceControlService.pullRequestCompareURL(projectRoot: repo)
        #expect(url?.absoluteString == "https://github.com/olii-dev/DemoApp/compare/main...feature/cool?expand=1")
    }

    @Test func pullRequestURLReturnsNilOnDefaultBranch() async throws {
        let repo = try Self.makeGitRepo(withRemote: "https://github.com/olii-dev/DemoApp.git")
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(SourceControlService.pullRequestCompareURL(projectRoot: repo) == nil)
    }

    @Test func pushWithoutRemoteFailsWithHelpfulError() async throws {
        let repo = try Self.makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        do {
            try SourceControlService.push(projectRoot: repo)
            #expect(Bool(false), "expected push without remote to fail")
        } catch let error as SourceControlService.SourceControlError {
            #expect(error.localizedDescription.contains("origin"))
        }
    }
}

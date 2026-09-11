import Foundation

/// User-facing source control on top of the git CLI: status, stage/commit, push,
/// and pull-request helpers. Complements `LatticeGitWorkspaceCheckpoint`, which
/// handles the internal retry/restore machinery.
enum SourceControlService {

    struct Status: Equatable {
        let isRepository: Bool
        let branch: String?
        let hasUpstream: Bool
        let dirtyCount: Int
        let untrackedCount: Int
        let aheadCount: Int
        let behindCount: Int
    }

    enum SourceControlError: LocalizedError {
        case notAGitRepository
        case gitFailed(operation: String, detail: String)
        case noRemoteConfigured

        var errorDescription: String? {
            switch self {
            case .notAGitRepository:
                return "This project isn't a git repository yet."
            case .gitFailed(let operation, let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(operation) failed\(trimmed.isEmpty ? "." : ":\n\n\(trimmed)")"
            case .noRemoteConfigured:
                return "No remote named “origin” is configured. Add one on github.com and run:\ngit remote add origin <url>"
            }
        }
    }

    // MARK: - Status

    static func status(projectRoot: URL) -> Status {
        let root = projectRoot.path
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            return Status(isRepository: false, branch: nil, hasUpstream: false,
                          dirtyCount: 0, untrackedCount: 0, aheadCount: 0, behindCount: 0)
        }
        let result = runGit(projectRoot: root, arguments: ["status", "--porcelain=v2", "--branch"])
        guard result.status == 0 else {
            return Status(isRepository: false, branch: nil, hasUpstream: false,
                          dirtyCount: 0, untrackedCount: 0, aheadCount: 0, behindCount: 0)
        }
        return parseStatus(result.output)
    }

    /// Parses `git status --porcelain=v2 --branch` output.
    static func parseStatus(_ text: String) -> Status {
        var branch: String?
        var hasUpstream = false
        var ahead = 0
        var behind = 0
        var dirty = 0
        var untracked = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                branch = (value == "(detached)") ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst("# branch.ab ".count)
                for part in counts.split(separator: " ") {
                    if part.hasPrefix("+"), let n = Int(part.dropFirst()) { ahead = n }
                    if part.hasPrefix("-"), let n = Int(part.dropFirst()) { behind = n }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                dirty += 1
            } else if line.hasPrefix("u ") {
                dirty += 1
            } else if line.hasPrefix("? ") || line.hasPrefix("?? ") {
                untracked += 1
            }
        }
        return Status(
            isRepository: true,
            branch: branch,
            hasUpstream: hasUpstream,
            dirtyCount: dirty,
            untrackedCount: untracked,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    // MARK: - Operations

    /// `git init` + initial commit, so history restore (checkpoints) and the
    /// source-control UI work from the very first session.
    static func initializeRepository(projectRoot: URL) throws {
        let root = projectRoot.path
        guard !FileManager.default.fileExists(atPath: root + "/.git") else { return }
        var result = runGit(projectRoot: root, arguments: ["init", "-b", "main"])
        guard result.status == 0 else {
            throw SourceControlError.gitFailed(operation: "init", detail: result.output)
        }
        result = runGit(projectRoot: root, arguments: ["add", "-A"])
        guard result.status == 0 else {
            throw SourceControlError.gitFailed(operation: "add", detail: result.output)
        }
        result = runGit(projectRoot: root, arguments: ["commit", "-m", "Initial commit"])
        // An empty initial commit is fine to fail (no files), everything else isn't.
        if result.status != 0,
           !result.output.localizedCaseInsensitiveContains("nothing to commit") {
            throw SourceControlError.gitFailed(operation: "commit", detail: result.output)
        }
    }

    static func stageAll(projectRoot: URL) throws {
        let result = runGit(projectRoot: projectRoot.path, arguments: ["add", "-A"])
        guard result.status == 0 else {
            throw SourceControlError.gitFailed(operation: "add", detail: result.output)
        }
    }

    static func commit(projectRoot: URL, message: String) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceControlError.gitFailed(operation: "commit", detail: "Commit message is empty.")
        }
        try stageAll(projectRoot: projectRoot)
        let result = runGit(projectRoot: projectRoot.path, arguments: ["commit", "-m", trimmed])
        guard result.status == 0 else {
            throw SourceControlError.gitFailed(operation: "commit", detail: result.output)
        }
    }

    /// Pushes the current branch. Sets upstream on first push; relies on the
    /// user's git credential setup (macOS keychain helper) for auth.
    static func push(projectRoot: URL) throws {
        let root = projectRoot.path
        guard let branch = currentBranch(projectRoot: projectRoot) else {
            throw SourceControlError.gitFailed(operation: "push", detail: "No current branch (detached HEAD).")
        }
        let status = parseStatus(runGit(projectRoot: root, arguments: ["status", "--porcelain=v2", "--branch"]).output)
        let arguments: [String]
        if status.hasUpstream {
            arguments = ["push"]
        } else {
            arguments = ["push", "-u", "origin", branch]
        }
        let result = runGit(projectRoot: root, arguments: arguments)
        guard result.status == 0 else {
            if result.output.localizedCaseInsensitiveContains("No configured push destination")
                || result.output.localizedCaseInsensitiveContains("'origin' does not appear to be a git repository") {
                throw SourceControlError.noRemoteConfigured
            }
            throw SourceControlError.gitFailed(operation: "push", detail: result.output)
        }
    }

    static func currentBranch(projectRoot: URL) -> String? {
        let result = runGit(projectRoot: projectRoot.path, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        guard result.status == 0 else { return nil }
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch.isEmpty || branch == "HEAD") ? nil : branch
    }

    // MARK: - Pull request helpers

    /// Extracts (owner, repo) from the `origin` remote URL (HTTPS or SSH forms).
    static func ownerRepo(fromRemoteURL url: String) -> (owner: String, repo: String)? {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }

        // HTTPS: https://github.com/owner/repo
        if let range = trimmed.range(of: "github.com/") {
            let rest = String(trimmed[range.upperBound...])
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                return (String(parts[0]), String(parts[1]))
            }
            return nil
        }
        // SSH: git@github.com:owner/repo or ssh://git@github.com/owner/repo
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let rest = String(trimmed[trimmed.index(after: colonIndex)...])
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, trimmed.contains("github.com") {
                return (String(parts[0]), String(parts[1]))
            }
        }
        return nil
    }

    static func remoteOriginURL(projectRoot: URL) -> String? {
        let result = runGit(projectRoot: projectRoot.path, arguments: ["remote", "get-url", "origin"])
        guard result.status == 0 else { return nil }
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Best-effort default branch of `origin` (falls back to "main").
    static func remoteDefaultBranch(projectRoot: URL) -> String {
        let result = runGit(
            projectRoot: projectRoot.path,
            arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"]
        )
        guard result.status == 0 else { return "main" }
        let ref = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = ref.split(separator: "/").last else { return "main" }
        return String(last)
    }

    /// Compare URL for opening a pre-filled PR on github.com.
    static func pullRequestCompareURL(projectRoot: URL) -> URL? {
        guard let remote = remoteOriginURL(projectRoot: projectRoot),
              let (owner, repo) = ownerRepo(fromRemoteURL: remote),
              let branch = currentBranch(projectRoot: projectRoot)
        else { return nil }
        let base = remoteDefaultBranch(projectRoot: projectRoot)
        guard branch != base else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/compare/\(base)...\(branch)?expand=1")
    }

    // MARK: - Git runner

    private static func runGit(projectRoot: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = SimulatorBuildRunner.subprocessEnvironment
        do {
            try process.run()
        } catch {
            return (Int32(-1), error.localizedDescription)
        }
        // Drain before waiting so large output cannot wedge on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

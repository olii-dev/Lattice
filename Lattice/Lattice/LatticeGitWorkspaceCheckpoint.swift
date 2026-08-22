import Foundation

/// Git checkpoints for Retry: persist end-of-turn snapshots and restore with `reset --hard` + `clean -fd`.
enum LatticeGitWorkspaceCheckpoint {

    struct RestoreResult: Equatable {
        let succeeded: Bool
        /// Human-readable failure detail; nil on success.
        let failureDetail: String?

        static func success() -> RestoreResult { .init(succeeded: true, failureDetail: nil) }
        static func failure(_ detail: String) -> RestoreResult {
            .init(succeeded: false, failureDetail: detail)
        }

        var isSuccess: Bool { succeeded }
    }

    private static let baselineKeyPrefix = "latticeGitRetryBaselineV1."

    static func persistRetryBaseline(projectFingerprint: String, oid: String) {
        let fp = projectFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fp.isEmpty, !oid.isEmpty else { return }
        UserDefaults.standard.set(oid, forKey: baselineKeyPrefix + fp)
    }

    static func loadRetryBaseline(projectFingerprint: String) -> String? {
        let fp = projectFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fp.isEmpty else { return nil }
        let v = UserDefaults.standard.string(forKey: baselineKeyPrefix + fp)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    static func clearRetryBaseline(projectFingerprint: String) {
        let fp = projectFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fp.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: baselineKeyPrefix + fp)
    }

    static func captureHead(worktree: String) -> String? {
        let root = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        guard isGitWorktree(root) else { return nil }
        let result = runGit(arguments: ["-C", root, "rev-parse", "HEAD"])
        guard result.succeeded else { return nil }
        let oid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// Dangling commit from `git stash create` (includes untracked when supported); falls back to `HEAD`.
    static func captureWorkingTreeSnapshot(worktree: String) -> String? {
        let root = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        guard isGitWorktree(root) else { return nil }
        let stash = runGit(arguments: ["-C", root, "stash", "create", "--include-untracked"])
        if stash.succeeded {
            let oid = stash.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !oid.isEmpty { return oid }
        }
        return captureHead(worktree: root)
    }

    /// Restores the worktree to `revision`. Never destroys anything until the revision is
    /// verified to exist; `clean -fd` only runs after a successful `reset --hard`.
    @discardableResult
    static func resetHardAndClean(worktree: String, revision: String) -> RestoreResult {
        let root = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !revision.isEmpty else {
            return .failure("Missing worktree or revision.")
        }
        guard isGitWorktree(root) else {
            return .failure("\(root) is not a git repository.")
        }

        // Refuse to destroy the working tree when the snapshot no longer resolves;
        // this guards against restores after a silently failed snapshot capture.
        let verify = runGit(arguments: ["-C", root, "rev-parse", "--verify", "\(revision)^{commit}"])
        guard verify.succeeded else {
            return .failure(
                "Snapshot revision \(revision) does not exist in this repository. "
                    + "The working tree was left unchanged."
            )
        }

        let reset = runGit(arguments: ["-C", root, "reset", "--hard", revision])
        guard reset.succeeded else {
            let detail = trimmedOutput(reset.output)
            return .failure("git reset --hard failed\(detail.isEmpty ? "." : ": \(detail)")")
        }

        let clean = runGit(arguments: ["-C", root, "clean", "-fd"])
        guard clean.succeeded else {
            let detail = trimmedOutput(clean.output)
            return .failure(
                "Files were reset to \(revision), but git clean failed"
                    + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
        return .success()
    }

    private static func trimmedOutput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGitWorktree(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(".git").path)
    }

    private struct GitRunResult {
        let succeeded: Bool
        let output: String
    }

    private static func runGit(arguments: [String]) -> GitRunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return GitRunResult(succeeded: false, output: error.localizedDescription)
        }
        // Read before waiting so large stderr cannot wedge on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GitRunResult(
            succeeded: p.terminationStatus == 0,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

import Foundation

/// Git checkpoints for Retry: persist end-of-turn snapshots and restore with `reset --hard` + `clean -fd`.
enum LatticeGitWorkspaceCheckpoint {

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
        let out = runGit(arguments: ["-C", root, "rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty else { return nil }
        return out
    }

    /// Dangling commit from `git stash create` (includes untracked when supported); falls back to `HEAD`.
    static func captureWorkingTreeSnapshot(worktree: String) -> String? {
        let root = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        guard isGitWorktree(root) else { return nil }
        let stashOut = runGit(arguments: ["-C", root, "stash", "create", "--include-untracked"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stashOut, !stashOut.isEmpty {
            return stashOut
        }
        return captureHead(worktree: root)
    }

    static func resetHardAndClean(worktree: String, revision: String) {
        let root = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !revision.isEmpty else { return }
        _ = runGit(arguments: ["-C", root, "reset", "--hard", revision])
        _ = runGit(arguments: ["-C", root, "clean", "-fd"])
    }

    private static func isGitWorktree(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(".git").path)
    }

    private static func runGit(arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

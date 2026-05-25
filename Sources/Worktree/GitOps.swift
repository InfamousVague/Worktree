import Foundation

/// Thin shell-out to `/usr/bin/git`. libgit2 + Swift bindings would
/// be more "proper" but: this is a menu-bar utility, git ops happen
/// at user-click rate, fork/exec cost is ~3ms, and shelling lets us
/// support whatever the user has installed (homebrew git, Apple
/// CLT git, fork variants) without ABI surface area.
///
/// Every method returns a `Result<String, GitError>` so the caller
/// can render an error string in the UI rather than crashing.
enum GitOps {
    enum GitError: Error, LocalizedError {
        case notARepo(String)
        case command(String, String) // stderr, command string
        case malformedOutput(String)

        var errorDescription: String? {
            switch self {
            case .notARepo(let p): return "Not a git repo: \(p)"
            case .command(let stderr, _):
                return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            case .malformedOutput(let s): return "Couldn't parse git output: \(s)"
            }
        }
    }

    // MARK: - Repo discovery

    /// Walk upward from `path` looking for a `.git` directory or
    /// file. Returns the *workdir* root (the directory containing
    /// `.git`), not the .git itself. For worktrees, `.git` is a
    /// file pointing at the linked git dir — same algorithm finds
    /// the working tree root either way.
    static func repoRoot(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // Resolve to an existing path — if `path` was a file, we
        // want to start at its containing directory.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           !isDir.boolValue {
            url = url.deletingLastPathComponent()
        }
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) { return url.path }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Read ops

    /// Current branch name. Returns "HEAD" for detached state.
    static func currentBranch(repo: String) -> Result<String, GitError> {
        run(["symbolic-ref", "--short", "HEAD"], cwd: repo).flatMap { out in
            let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(s.isEmpty ? "HEAD" : s)
        }.flatMapError { _ in
            // Detached HEAD path: symbolic-ref errors out. Fall
            // back to the short SHA.
            run(["rev-parse", "--short", "HEAD"], cwd: repo).map { out in
                out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Local branches, newest-committed first.
    static func localBranches(repo: String) -> Result<[String], GitError> {
        run([
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads/",
        ], cwd: repo).map { out in
            out.split(separator: "\n").map(String.init)
        }
    }

    /// Remote branches, newest-committed first. Filters out the
    /// symbolic-ref entries (`origin/HEAD`) so the UI only sees
    /// actual remote branches a user can switch to.
    static func remoteBranches(repo: String) -> Result<[String], GitError> {
        run([
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/remotes/",
        ], cwd: repo).map { out in
            out.split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasSuffix("/HEAD") }
        }
    }

    /// Create + switch to a local tracking branch from a remote ref.
    /// `remote` is the short remote-branch name like
    /// `origin/feature/foo`. Git's `--track` form figures out the
    /// local name (`feature/foo`) automatically.
    static func switchTracking(remote: String, repo: String)
        -> Result<Void, GitError>
    {
        run(["switch", "--track", remote], cwd: repo).map { _ in () }
    }

    /// `(short_status, ahead, behind, dirty_count)` — the bits the
    /// menu bar dropdown actually needs. `git status --porcelain
    /// --branch` returns all of it in one call so we don't pay 4×
    /// fork/exec.
    struct Status {
        var ahead: Int = 0
        var behind: Int = 0
        var dirty: Int = 0   // unstaged + staged + untracked files
    }

    static func status(repo: String) -> Result<Status, GitError> {
        run(["status", "--porcelain=v1", "--branch"], cwd: repo).map { out in
            var st = Status()
            for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if l.hasPrefix("##") {
                    // e.g. `## main...origin/main [ahead 2, behind 1]`
                    if let r = l.range(of: "ahead "),
                       let n = Int(l[r.upperBound...]
                                     .prefix(while: { $0.isNumber })) {
                        st.ahead = n
                    }
                    if let r = l.range(of: "behind "),
                       let n = Int(l[r.upperBound...]
                                     .prefix(while: { $0.isNumber })) {
                        st.behind = n
                    }
                } else if !l.isEmpty {
                    st.dirty += 1
                }
            }
            return st
        }
    }

    struct Worktree {
        let path: String
        let head: String      // commit SHA or "(bare)"
        let branch: String?   // nil = detached
        let isMain: Bool
    }

    /// `git worktree list --porcelain` parser. The main worktree is
    /// the first entry; linked worktrees follow.
    static func worktrees(repo: String) -> Result<[Worktree], GitError> {
        run(["worktree", "list", "--porcelain"], cwd: repo).map { out in
            var results: [Worktree] = []
            var path: String?
            var head: String?
            var branch: String?
            for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.hasPrefix("worktree ") {
                    if let p = path {
                        results.append(Worktree(
                            path: p,
                            head: head ?? "",
                            branch: branch,
                            isMain: results.isEmpty
                        ))
                    }
                    path = String(line.dropFirst("worktree ".count))
                    head = nil; branch = nil
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    // e.g. `branch refs/heads/feature/foo` — strip prefix.
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
                }
            }
            if let p = path {
                results.append(Worktree(
                    path: p,
                    head: head ?? "",
                    branch: branch,
                    isMain: results.isEmpty
                ))
            }
            return results
        }
    }

    // MARK: - Write ops

    /// Switch the current worktree to `branch`. Fails if the
    /// worktree is dirty (matching `git switch`'s default safety).
    static func switchBranch(_ branch: String, repo: String)
        -> Result<Void, GitError>
    {
        run(["switch", branch], cwd: repo).map { _ in () }
    }

    /// Create a new branch from `from` and switch to it.
    static func createBranch(_ name: String,
                             from: String? = nil,
                             repo: String)
        -> Result<Void, GitError>
    {
        var args = ["switch", "-c", name]
        if let from { args.append(from) }
        return run(args, cwd: repo).map { _ in () }
    }

    /// Create a linked worktree at `path` checked out to `branch`.
    /// `branch` can be an existing branch (it'll be checked out
    /// there) or a new branch name (use `createNewBranch: true` to
    /// create-and-check-out in one step).
    static func addWorktree(
        path: String,
        branch: String,
        createNewBranch: Bool,
        from: String? = nil,
        repo: String
    ) -> Result<Void, GitError> {
        var args = ["worktree", "add"]
        if createNewBranch {
            args.append("-b")
            args.append(branch)
        }
        args.append(path)
        if !createNewBranch { args.append(branch) }
        if createNewBranch, let from { args.append(from) }
        return run(args, cwd: repo).map { _ in () }
    }

    /// Network ops — return stdout/stderr concatenated so the UI
    /// can show the success message ("Already up to date" etc).
    static func fetch(repo: String) -> Result<String, GitError> {
        run(["fetch", "--all", "--prune"], cwd: repo)
    }

    static func pull(repo: String) -> Result<String, GitError> {
        run(["pull", "--ff-only"], cwd: repo)
    }

    // MARK: - Runner

    /// One spot that touches `Process`. Synchronous on the calling
    /// thread — caller dispatches to a background queue for ops
    /// that might block (fetch, pull, status on huge repos).
    private static func run(_ args: [String],
                            cwd: String) -> Result<String, GitError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        do {
            try p.run()
        } catch {
            return .failure(.command(error.localizedDescription,
                                     "git " + args.joined(separator: " ")))
        }
        p.waitUntilExit()
        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        if p.terminationStatus == 0 {
            return .success(out)
        }
        return .failure(.command(err, "git " + args.joined(separator: " ")))
    }
}

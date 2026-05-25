import AppKit
import Foundation
import Observation

/// Worktree's single source of truth. Holds the currently-focused
/// repo + its branch + worktree list + dirty status, observes
/// frontmost-app focus changes to refresh, exposes the git ops
/// the popover UI fires.
///
/// "Sticky" behaviour: when the user focuses a non-coding app
/// (Mail, Slack, etc.), we keep showing the last-known repo
/// rather than blanking the menu bar. That makes the indicator
/// feel like state, not a live feed that's mostly silent.
@MainActor
@Observable
final class WorktreeStore {
    /// What the menu bar + popover render against.
    struct RepoSnapshot: Equatable {
        let path: String              // absolute worktree root
        let displayName: String       // last path component
        let branch: String            // "main" or "(detached)"
        let ahead: Int
        let behind: Int
        let dirty: Int
        let worktrees: [WorktreeEntry]
        let localBranches: [String]
    }

    struct WorktreeEntry: Equatable, Identifiable {
        let id: String                // = path
        let path: String
        let branch: String?
        let isCurrent: Bool           // matches the repo we're focused in
        let isMain: Bool              // the original (non-linked) worktree
    }

    /// The repo currently shown in the menu bar. Sticky — only
    /// updates when we resolve a NEW repo from focus change; an
    /// unresolvable focus keeps the previous snapshot.
    private(set) var current: RepoSnapshot?

    /// Most recent error from a git op. Cleared on the next
    /// successful op or by the UI dismissing it.
    var lastError: String?

    /// Set true while a long-running git op (fetch/pull) is in
    /// flight so the UI can show a spinner.
    private(set) var busy: Bool = false

    @ObservationIgnored private let resolver = ContextResolver()
    @ObservationIgnored private var focusObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func start() {
        refreshFromFocus()
        focusObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshFromFocus() }
            }
    }

    func stop() {
        if let o = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            focusObserver = nil
        }
    }

    /// Re-run the resolver + git lookups. Triggered on focus
    /// change, popover open, and manual refresh.
    func refreshFromFocus() {
        guard let path = resolver.currentPath(),
              let root = GitOps.repoRoot(containing: path)
        else {
            // No repo found — keep the previous sticky snapshot.
            return
        }
        loadSnapshot(repoRoot: root)
    }

    /// Reload the snapshot for an already-known repo (after a
    /// branch switch / worktree add / pull).
    func reloadCurrent() {
        guard let root = current?.path else { return }
        loadSnapshot(repoRoot: root)
    }

    private func loadSnapshot(repoRoot: String) {
        let branch: String
        switch GitOps.currentBranch(repo: repoRoot) {
        case .success(let b): branch = b
        case .failure(let e):
            lastError = e.localizedDescription
            return
        }
        let status: GitOps.Status = {
            switch GitOps.status(repo: repoRoot) {
            case .success(let s): return s
            case .failure: return GitOps.Status()
            }
        }()
        let worktrees: [WorktreeEntry] = {
            switch GitOps.worktrees(repo: repoRoot) {
            case .success(let ws):
                return ws.map { w in
                    WorktreeEntry(
                        id: w.path,
                        path: w.path,
                        branch: w.branch,
                        isCurrent: w.path == repoRoot,
                        isMain: w.isMain
                    )
                }
            case .failure: return []
            }
        }()
        let branches: [String] = {
            switch GitOps.localBranches(repo: repoRoot) {
            case .success(let bs): return bs
            case .failure: return [branch]
            }
        }()
        current = RepoSnapshot(
            path: repoRoot,
            displayName: URL(fileURLWithPath: repoRoot).lastPathComponent,
            branch: branch,
            ahead: status.ahead,
            behind: status.behind,
            dirty: status.dirty,
            worktrees: worktrees,
            localBranches: branches
        )
    }

    // MARK: - Write ops (UI-triggered)

    func switchBranch(_ branch: String) {
        guard let snap = current else { return }
        if snap.dirty > 0 {
            lastError = "Worktree has \(snap.dirty) uncommitted change(s). "
                + "Commit or stash before switching branches."
            return
        }
        switch GitOps.switchBranch(branch, repo: snap.path) {
        case .success: lastError = nil; reloadCurrent()
        case .failure(let e): lastError = e.localizedDescription
        }
    }

    func createBranch(_ name: String) {
        guard let snap = current else { return }
        switch GitOps.createBranch(name, repo: snap.path) {
        case .success: lastError = nil; reloadCurrent()
        case .failure(let e): lastError = e.localizedDescription
        }
    }

    func createWorktree(branchName: String,
                        createNew: Bool,
                        atPath path: String) {
        guard let snap = current else { return }
        switch GitOps.addWorktree(
            path: path,
            branch: branchName,
            createNewBranch: createNew,
            from: createNew ? snap.branch : nil,
            repo: snap.path
        ) {
        case .success: lastError = nil; reloadCurrent()
        case .failure(let e): lastError = e.localizedDescription
        }
    }

    /// Long-running. Dispatched to a background queue + flips
    /// `busy` so the popover can show a spinner.
    func fetch() {
        guard let snap = current else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = GitOps.fetch(repo: snap.path)
            await MainActor.run {
                self.busy = false
                switch result {
                case .success: self.lastError = nil; self.reloadCurrent()
                case .failure(let e): self.lastError = e.localizedDescription
                }
            }
        }
    }

    func pull() {
        guard let snap = current else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = GitOps.pull(repo: snap.path)
            await MainActor.run {
                self.busy = false
                switch result {
                case .success: self.lastError = nil; self.reloadCurrent()
                case .failure(let e): self.lastError = e.localizedDescription
                }
            }
        }
    }
}

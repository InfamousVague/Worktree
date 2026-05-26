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
        /// Remote branches in the form `origin/feature-foo`, with
        /// the `origin/HEAD` symbolic ref filtered out. Tapping
        /// one creates a local tracking branch.
        let remoteBranches: [String]
    }

    struct WorktreeEntry: Equatable, Identifiable {
        let id: String                // = path
        let path: String
        let branch: String?
        let isCurrent: Bool           // matches the repo we're focused in
        let isMain: Bool              // the original (non-linked) worktree
    }

    /// User-saved project. Path is the unique identifier — same
    /// repo can't be saved twice. `lastKnownBranch` is refreshed
    /// every time we load a snapshot for that path; it lets the
    /// SAVED list show fresh branch info without doing per-row
    /// git invocations every time the popover opens.
    struct SavedProject: Codable, Identifiable, Equatable {
        var id: String { path }
        let path: String
        let displayName: String
        var lastKnownBranch: String?
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

    /// User-saved projects, persisted across launches via
    /// UserDefaults. Order is "most recently saved first" — the
    /// SAVED list in the popover renders in this order.
    private(set) var savedProjects: [SavedProject] = []

    /// When non-nil, `refreshFromFocus()` ignores the resolver and
    /// re-loads this path instead. Set by `viewSaved(_:)`, cleared
    /// by `returnToFocus()`. Lets the user operate on a saved
    /// project even when the IDE focus has moved elsewhere.
    private(set) var pinnedPath: String?

    var isPinned: Bool { pinnedPath != nil }

    /// True when the currently-displayed snapshot's path is in
    /// `savedProjects`. The header's bookmark toggle reads this.
    var currentIsSaved: Bool {
        guard let p = current?.path else { return false }
        return savedProjects.contains(where: { $0.path == p })
    }

    @ObservationIgnored private let resolver = ContextResolver()
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private let savedProjectsKey = "worktree.savedProjects"
    /// Refresh the live-activity payload at this cadence so
    /// Halo's 30s TTL never expires the pill. Cheap — one
    /// JSON write per tick.
    @ObservationIgnored private var liveActivityTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        loadSavedProjects()
        refreshFromFocus()
        // Publish an initial pill even if the resolver can't
        // find a focused repo yet — Worktree is "presence" UI,
        // it should be visible as soon as the app is running.
        publishLiveActivity()
        liveActivityTimer = Timer.scheduledTimer(
            withTimeInterval: 5, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishLiveActivity() }
        }
        // Halo's expanded card posts this when the user picks
        // a branch from the dropdown. Object string is the
        // target branch name.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(
                "com.mattssoftware.worktree.switchBranch"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let branch = note.object as? String,
                  !branch.isEmpty else { return }
            Task { @MainActor in
                self?.switchBranchWithAutoStash(to: branch)
            }
        }
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
        liveActivityTimer?.invalidate()
        liveActivityTimer = nil
        clearLiveActivity()
    }

    /// Re-run the resolver + git lookups. Triggered on focus
    /// change, popover open, and manual refresh.
    ///
    /// When `pinnedPath` is set (the user explicitly chose to view
    /// a saved project), the resolver is skipped — we always show
    /// the pinned project regardless of what's frontmost. That
    /// lets the user keep operating on the saved project even
    /// after they Cmd-Tab away from it.
    func refreshFromFocus() {
        if let pinned = pinnedPath {
            loadSnapshot(repoRoot: pinned)
            return
        }
        // Strict editor-only path: skips GenericCWDAdapter so a
        // focus change to Mail / Slack / Spotify doesn't move
        // the indicator. Sticky snapshot from the last verified
        // editor focus stays in place.
        guard let path = resolver.currentEditorPath(),
              let root = GitOps.repoRoot(containing: path)
        else {
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
            case .success(let bs) where !bs.isEmpty: return bs
            case .success:
                // Suspicious: for-each-ref returned no rows for a
                // repo we just confirmed has a current branch. Log
                // so it shows up in Console.app and fall back to
                // the single current branch — at least the user
                // can see *something* to switch from.
                NSLog("Worktree: localBranches returned empty for \(repoRoot); falling back to [\(branch)]")
                return [branch]
            case .failure(let e):
                NSLog("Worktree: localBranches failed for \(repoRoot): \(e.localizedDescription)")
                return [branch]
            }
        }()
        let remotes: [String] = {
            switch GitOps.remoteBranches(repo: repoRoot) {
            case .success(let rs): return rs
            case .failure: return []
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
            localBranches: branches,
            remoteBranches: remotes
        )
        // Keep saved-project branch labels current. The popover's
        // SAVED list renders this without doing its own git work.
        if let idx = savedProjects.firstIndex(where: { $0.path == repoRoot }),
           savedProjects[idx].lastKnownBranch != branch {
            savedProjects[idx].lastKnownBranch = branch
            persistSavedProjects()
        }
        publishLiveActivity()
    }

    /// Surface the current repo + branch in the system-wide
    /// island (Halo). Worktree isn't a SuiteKit pane — it's a
    /// standalone agent that ships its own .app — so we write
    /// the JSON inline rather than linking SuiteKit just for
    /// one payload type. Format mirrors `SuiteLiveActivityStore
    /// .Payload`; Halo reads it from the shared directory.
    ///
    /// Published even when `current` is nil (no repo focused
    /// yet) — Worktree is "presence" UI and should be visible
    /// in the island as soon as the agent starts, not just
    /// once the user happens to focus a coding window. The
    /// idle pill shows the app name so the user can tell
    /// Halo is seeing Worktree.
    private func publishLiveActivity() {
        // Default-quiet: only surface in Halo when the user is
        // actively in an editor + we know the repo. Browsing
        // Mail / Slack / Spotify → Worktree quietly clears its
        // slot so the island can disappear if nothing else is
        // worth showing.
        guard resolver.currentEditorPath() != nil,
              let snap = current else {
            HaloLiveActivityWriter.clear("worktree")
            return
        }
        let dirtyMarker = snap.dirty > 0 ? "*" : ""
        let label = "\(snap.displayName)·\(snap.branch)\(dirtyMarker)"
        let extras = WorktreeData(
            repoPath: snap.path,
            currentBranch: snap.branch,
            branches: snap.localBranches,
            isDirty: snap.dirty > 0)
        // "worktree.git" is a special id Halo maps to the
        // bundled Git logo (CC BY 3.0, Jason Long).
        let payload = HaloLiveActivityPayload(
            compactLeadingSymbol: "worktree.git",
            compactTrailingText: label,
            compactTrailingSymbol: nil,
            tintHex: "#7CB377",
            priority: 50,
            updatedAt: Date().timeIntervalSince1970,
            worktree: extras)
        HaloLiveActivityWriter.write(payload, for: "worktree")
    }

    /// Withdraw the worktree pill — called when Worktree quits
    /// (otherwise the 30s TTL in Halo cleans up anyway).
    func clearLiveActivity() {
        HaloLiveActivityWriter.clear("worktree")
    }

    // MARK: - Saved projects

    /// Add the currently-displayed project to the saved list, or
    /// remove it if it's already there.
    func toggleSaveCurrent() {
        guard let snap = current else { return }
        if let idx = savedProjects.firstIndex(where: { $0.path == snap.path }) {
            savedProjects.remove(at: idx)
            // If we were pinned to this one, unpin too — keeping a
            // pin to a project the user just unsaved feels wrong.
            if pinnedPath == snap.path { pinnedPath = nil }
        } else {
            // New saves go to the top of the list (LRU-ish), so
            // the most-frequently-toggled projects stay visible
            // without scrolling.
            savedProjects.insert(SavedProject(
                path: snap.path,
                displayName: snap.displayName,
                lastKnownBranch: snap.branch
            ), at: 0)
        }
        persistSavedProjects()
    }

    /// Pin the popover view to a saved project. Loads its
    /// snapshot synchronously so the UI updates immediately.
    func viewSaved(_ project: SavedProject) {
        pinnedPath = project.path
        loadSnapshot(repoRoot: project.path)
    }

    /// Clear the pin and resume auto-following focus.
    func returnToFocus() {
        pinnedPath = nil
        refreshFromFocus()
    }

    /// Drop a project from the saved list without changing what's
    /// currently displayed. Wired to the row's context menu.
    func removeSaved(_ project: SavedProject) {
        savedProjects.removeAll { $0.path == project.path }
        if pinnedPath == project.path {
            pinnedPath = nil
            refreshFromFocus()
        }
        persistSavedProjects()
    }

    private func persistSavedProjects() {
        guard let data = try? JSONEncoder().encode(savedProjects) else { return }
        UserDefaults.standard.set(data, forKey: savedProjectsKey)
    }

    private func loadSavedProjects() {
        guard let data = UserDefaults.standard.data(forKey: savedProjectsKey),
              let projects = try? JSONDecoder().decode([SavedProject].self,
                                                       from: data)
        else { return }
        savedProjects = projects
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

    /// Check out a remote ref as a new local tracking branch. The
    /// remote name is the short form (e.g. `origin/feature-foo`);
    /// git's `switch --track` derives the local branch name from
    /// the trailing path component.
    func checkoutRemote(_ remoteRef: String) {
        guard let snap = current else { return }
        if snap.dirty > 0 {
            lastError = "Worktree has \(snap.dirty) uncommitted change(s). "
                + "Commit or stash before checking out a new branch."
            return
        }
        switch GitOps.switchTracking(remote: remoteRef, repo: snap.path) {
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

    /// Branch switch from Halo's expanded card. Auto-stashes
    /// when the working tree is dirty, switches, then pops.
    /// If the pop conflicts we leave the stash in place and
    /// expose the message — same gesture Worktree's popover
    /// would have run by hand.
    func switchBranchWithAutoStash(to branch: String) {
        guard let snap = current else { return }
        // No-op when the user clicked the already-current
        // branch (defensive — Halo filters it but trust no UI).
        if snap.branch == branch { return }

        let didStash: Bool
        if snap.dirty > 0 {
            // Tag the stash so the user knows where it came
            // from when they see `git stash list`.
            let msg =
                "halo-auto: switching from \(snap.branch) to \(branch)"
            switch GitOps.stashPush(message: msg,
                                    repo: snap.path) {
            case .success:
                didStash = true
            case .failure(let e):
                lastError = "stash failed: \(e.localizedDescription)"
                return
            }
        } else {
            didStash = false
        }

        switch GitOps.switchBranch(branch, repo: snap.path) {
        case .success:
            lastError = nil
        case .failure(let e):
            // Restore the user's changes before bailing —
            // failing to switch shouldn't leave them mid-stash.
            if didStash {
                _ = GitOps.stashPop(repo: snap.path)
            }
            lastError = "switch failed: \(e.localizedDescription)"
            return
        }

        if didStash {
            switch GitOps.stashPop(repo: snap.path) {
            case .success:
                lastError = nil
            case .failure(let e):
                // Don't drop the stash — let the user resolve
                // by hand from the popover or terminal.
                lastError =
                    "switched to \(branch) but auto-stash pop conflicted: \(e.localizedDescription)"
            }
        }

        reloadCurrent()
        publishLiveActivity()
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

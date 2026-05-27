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

    /// Wall-clock time of the most recent `fetch()` for the
    /// current repo. Used by `fetchIfStale()` to throttle the
    /// auto-fetch Halo posts on every expanded-card hover.
    private(set) var lastFetchAt: Date?

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
    /// Subscribers + poll timer for Halo's command channel.
    /// Halo posts a distributed notification on every queue
    /// append; the poll is a belt-and-suspenders fallback for
    /// the rare case where the notification is missed
    /// (subscribe race, mid-launch arrivals, etc).
    @ObservationIgnored private var commandsObserver: NSObjectProtocol?
    @ObservationIgnored private var commandsPollTimer: Timer?
    /// UUIDs we've already executed — dedup guard so a stale
    /// queue read or a Halo re-write doesn't double-fire a
    /// command. Capped at a few hundred entries to bound memory;
    /// older entries get pruned in `drainCommands`.
    @ObservationIgnored private var processedCommandIDs: Set<String> = []

    // MARK: - Focus-driven priority boost
    //
    // When the user newly focuses an editor (i.e. their previous
    // frontmost app was not an editor), the worktree pill briefly
    // takes precedence in the island so they get a flash of "yes,
    // we know this repo / branch" before higher-priority activities
    // (Espresso, Now Playing) reclaim the slot.
    /// Did the most recent `refreshFromFocus` tick see an editor?
    /// Used to detect the non-editor → editor transition that
    /// triggers the boost.
    @ObservationIgnored private var wasInEditor: Bool = false
    /// Publish at boosted priority until this date. Nil means
    /// "publish at the normal baseline."
    @ObservationIgnored private var priorityBoostUntil: Date?
    /// Timer that re-publishes at the normal priority once the
    /// boost window expires. Invalidated + replaced on overlap.
    @ObservationIgnored private var boostRevertTimer: Timer?
    /// Baseline priority. Lower than Espresso (60) and Now
    /// Playing (70) so those reclaim the slot when worktree
    /// isn't actively claiming attention.
    private let worktreeBasePriority = 50
    /// Boosted priority during the focus-flash window. Has to
    /// out-rank Espresso's 60 so the worktree pill momentarily
    /// wins even with a keep-awake session running.
    private let worktreeBoostedPriority = 80
    /// How long the focus-flash boost lasts before reverting.
    private let worktreeBoostDuration: TimeInterval = 2.5

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
        // Halo command channel — distributed notification on
        // append + 1Hz fallback poll. Drain on either signal.
        commandsObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: Notification.Name(
                    "com.mattssoftware.worktree.commands.posted"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.drainCommands() }
            }
        commandsPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.drainCommands() }
        }
        // Drain any commands already queued before we registered.
        drainCommands()
    }

    func stop() {
        if let o = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            focusObserver = nil
        }
        if let o = commandsObserver {
            DistributedNotificationCenter.default().removeObserver(o)
            commandsObserver = nil
        }
        commandsPollTimer?.invalidate()
        commandsPollTimer = nil
        liveActivityTimer?.invalidate()
        liveActivityTimer = nil
        boostRevertTimer?.invalidate()
        boostRevertTimer = nil
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
        let editorPath = resolver.currentEditorPath()
        let inEditor = editorPath != nil
        // Only flash the boost when transitioning *into* an
        // editor from outside one. Clicking around inside the
        // same editor leaves `wasInEditor` true, so no boost.
        let justEnteredEditor = inEditor && !wasInEditor
        wasInEditor = inEditor

        guard let path = editorPath,
              let root = GitOps.repoRoot(containing: path)
        else {
            return
        }
        if justEnteredEditor {
            beginFocusPriorityBoost()
        }
        loadSnapshot(repoRoot: root)
    }

    /// Start the focus-flash window: set `priorityBoostUntil`
    /// to "now + boost duration", republish immediately so the
    /// elevated priority takes effect, and schedule a revert at
    /// expiry so the next pill cycle drops back to baseline.
    private func beginFocusPriorityBoost() {
        priorityBoostUntil = Date().addingTimeInterval(
            worktreeBoostDuration)
        boostRevertTimer?.invalidate()
        boostRevertTimer = Timer.scheduledTimer(
            withTimeInterval: worktreeBoostDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.priorityBoostUntil = nil
                self?.publishLiveActivity()
            }
        }
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
        // Reset the auto-fetch throttle when the repo changes —
        // switching projects should refetch immediately on the
        // next hover, even if we fetched the previous repo
        // seconds ago.
        if current?.path != repoRoot { lastFetchAt = nil }
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
        // Map our in-memory model into the JSON shape Halo's
        // rich-state decoder expects. Saved projects + worktrees
        // get flattened to Codable-only types — Halo never sees
        // our WorktreeEntry / SavedProject directly.
        let worktreeEntries = snap.worktrees.map {
            WorktreeEntryData(
                path: $0.path,
                branch: $0.branch,
                isCurrent: $0.isCurrent,
                isMain: $0.isMain)
        }
        let savedFlat = savedProjects.map {
            SavedProjectData(
                path: $0.path,
                displayName: $0.displayName,
                lastKnownBranch: $0.lastKnownBranch)
        }
        let extras = WorktreeData(
            repoPath: snap.path,
            displayName: snap.displayName,
            currentBranch: snap.branch,
            branches: snap.localBranches,
            remoteBranches: snap.remoteBranches,
            isDirty: snap.dirty > 0,
            ahead: snap.ahead,
            behind: snap.behind,
            dirtyCount: snap.dirty,
            worktrees: worktreeEntries,
            savedProjects: savedFlat,
            isPinned: isPinned,
            lastError: lastError)
        // "worktree.git" is a special id Halo maps to the
        // bundled Git logo (CC BY 3.0, Jason Long).
        let boostActive = priorityBoostUntil.map { $0 > Date() }
            ?? false
        let priority = boostActive
            ? worktreeBoostedPriority
            : worktreeBasePriority
        let payload = HaloLiveActivityPayload(
            compactLeadingSymbol: "worktree.git",
            compactTrailingText: label,
            compactTrailingSymbol: nil,
            tintHex: "#7CB377",
            priority: priority,
            updatedAt: Date().timeIntervalSince1970,
            worktree: extras)
        HaloLiveActivityWriter.write(payload, for: "worktree")
    }

    /// Withdraw the worktree pill — called when Worktree quits
    /// (otherwise the 30s TTL in Halo cleans up anyway).
    func clearLiveActivity() {
        HaloLiveActivityWriter.clear("worktree")
    }

    // MARK: - Halo command channel

    /// Read the command queue, execute anything not yet seen,
    /// and write back the empty queue. Idempotent — safe to
    /// call from both the distributed-notification observer
    /// and the 1Hz fallback poll.
    private func drainCommands() {
        let queue = HaloCommandReader.read(for: "worktree")
        guard !queue.commands.isEmpty else { return }
        var stillProcessed = processedCommandIDs
        for cmd in queue.commands where !stillProcessed.contains(cmd.id) {
            execute(cmd)
            stillProcessed.insert(cmd.id)
        }
        // Cap the processed set so a long-running session doesn't
        // grow memory unbounded — 500 ids = a couple minutes of
        // heavy clicking, far past anything we need to remember.
        if stillProcessed.count > 500 {
            // Keep only the most recent 250 — the ordering doesn't
            // matter for correctness, just for retention.
            stillProcessed = Set(stillProcessed.prefix(250))
        }
        processedCommandIDs = stillProcessed
        // Drain: write back an empty queue so Halo's next poll
        // sees a clean slate. This is where a Halo append could
        // race with our drain — accepted as v1 design (1Hz
        // cadence on both sides + processed-id dedup makes
        // duplicate execution impossible, command loss
        // statistically rare).
        HaloCommandReader.write(
            WorktreeCommandQueue(commands: [],
                                  updatedAt: Date().timeIntervalSince1970),
            for: "worktree")
    }

    /// Dispatch a single command to the matching `WorktreeStore`
    /// method. Unknown actions are no-ops — forward-compatibility
    /// with newer Halo versions.
    private func execute(_ cmd: WorktreeCommand) {
        switch cmd.action {
        case "switchBranch":
            if let b = cmd.branch, !b.isEmpty {
                switchBranchWithAutoStash(to: b)
            }
        case "createBranch":
            if let b = cmd.branch, !b.isEmpty { createBranch(b) }
        case "fetch":
            fetch()
        case "fetchIfStale":
            fetchIfStale()
        case "pull":
            pull()
        case "checkoutRemote":
            if let r = cmd.ref, !r.isEmpty { checkoutRemote(r) }
        case "toggleSaveCurrent":
            toggleSaveCurrent()
        case "viewSaved":
            if let p = cmd.path,
               let project = savedProjects.first(where: { $0.path == p }) {
                viewSaved(project)
            }
        case "returnToFocus":
            returnToFocus()
        case "removeSaved":
            if let p = cmd.path,
               let project = savedProjects.first(where: { $0.path == p }) {
                removeSaved(project)
            }
        case "addWorktree":
            if let b = cmd.branch, !b.isEmpty,
               let p = cmd.path, !p.isEmpty {
                createWorktree(branchName: b,
                               createNew: cmd.createNew ?? true,
                               atPath: p)
            }
        case "openInFinder":
            if let p = cmd.path, !p.isEmpty {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: p))
            }
        default:
            NSLog("Worktree: unknown command action \(cmd.action)")
        }
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
        lastFetchAt = Date()
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

    /// Cheap auto-fetch. Halo posts this from its expanded-card
    /// `onAppear` so the user gets fresh remote-branch / ahead-
    /// behind data as soon as they hover. Throttled — repeated
    /// hovers within `autoFetchCooldown` no-op so a cursor
    /// wiggling over the island doesn't pummel the network.
    func fetchIfStale() {
        if let last = lastFetchAt,
           Date().timeIntervalSince(last) < autoFetchCooldown {
            return
        }
        fetch()
    }

    /// Minimum gap between auto-fetches triggered by Halo's
    /// `fetchIfStale` command. Long enough that bouncing on /
    /// off the island doesn't refetch every wiggle; short
    /// enough that the data stays current when the user is
    /// actively reviewing branches.
    private let autoFetchCooldown: TimeInterval = 30

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

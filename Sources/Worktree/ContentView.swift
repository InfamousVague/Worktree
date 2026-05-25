import SwiftUI

/// Popover for the menu bar. Renders the current repo + branch
/// + worktree list + actions. Stays compact (320 wide) to match
/// the rest of the MattsSoftware suite's menu-bar UIs.
struct ContentView: View {
    @Environment(WorktreeStore.self) private var store

    @State private var showingNewBranch = false
    @State private var newBranchName = ""

    @State private var showingNewWorktree = false
    @State private var worktreeBranchName = ""
    @State private var worktreeCreateNew = true
    @State private var worktreePath = ""

    var body: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let snap = store.current {
                content(snap)
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            gitGlyph(size: 12)
                .foregroundStyle(.tint)
            Text("WORKTREE")
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
            Spacer()
            Button {
                store.refreshFromFocus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Refresh from current focus")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ snap: WorktreeStore.RepoSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Follow focus" banner — only shown when the user is
            // pinned to a saved project, so they know how to get
            // back to focus-follow mode.
            if store.isPinned {
                followFocusBanner
            }

            // Repo + branch summary
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snap.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    // Bookmark toggle — fills when this project is
                    // in the saved list. Tapping toggles save state.
                    Button {
                        store.toggleSaveCurrent()
                    } label: {
                        Image(systemName: store.currentIsSaved
                              ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 12))
                            .foregroundStyle(store.currentIsSaved
                                             ? Color.accentColor
                                             : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(store.currentIsSaved
                          ? "Remove from saved projects"
                          : "Save this project")
                }
                HStack(spacing: 6) {
                    gitGlyph(size: 10)
                        .foregroundStyle(.secondary)
                    Text(snap.branch)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    if snap.ahead > 0 || snap.behind > 0 || snap.dirty > 0 {
                        statusPills(snap)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Divider()

            // Branches list (scrollable when long). Heading carries
            // an inline fetch button — runs `git fetch --all
            // --prune` so the REMOTES list picks up branches the
            // user's collaborators just pushed.
            branchesHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snap.localBranches, id: \.self) { name in
                        branchRow(name, current: name == snap.branch)
                    }
                    if !snap.remoteBranches.isEmpty {
                        remotesSubheader(count: snap.remoteBranches.count)
                        ForEach(snap.remoteBranches, id: \.self) { name in
                            remoteBranchRow(name)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            Divider()

            // Worktrees list
            sectionLabel("WORKTREES (\(snap.worktrees.count))")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snap.worktrees) { w in
                    worktreeRow(w)
                }
            }

            // Saved projects list — only shown when there's at
            // least one. Tapping a row pins the popover view to
            // that project; right-click removes it from the list.
            if !store.savedProjects.isEmpty {
                Divider()
                sectionLabel("SAVED (\(store.savedProjects.count))")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.savedProjects) { p in
                        savedRow(p, currentPath: snap.path)
                    }
                }
            }

            // Error banner
            if let err = store.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
        }
        .sheet(isPresented: $showingNewBranch) { newBranchSheet }
        .sheet(isPresented: $showingNewWorktree) { newWorktreeSheet(snap) }
    }

    private func statusPills(_ snap: WorktreeStore.RepoSnapshot) -> some View {
        HStack(spacing: 4) {
            if snap.ahead > 0 {
                pill(text: "↑\(snap.ahead)", tint: .green)
            }
            if snap.behind > 0 {
                pill(text: "↓\(snap.behind)", tint: .orange)
            }
            if snap.dirty > 0 {
                pill(text: "\(snap.dirty)*", tint: .yellow)
            }
        }
    }

    /// The official Git logo, rendered as a template image so
    /// SwiftUI's `.foregroundStyle(...)` can tint it the same way
    /// it tints SF Symbols. Lives in
    /// `Assets.xcassets/MenuBarIcon.imageset` with
    /// `template-rendering-intent` set to `template`. Sized to
    /// match the SF Symbol it replaced (which was font-driven —
    /// the size argument here is the rough pt-equivalent).
    private func gitGlyph(size: CGFloat) -> some View {
        Image("MenuBarIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
    }

    /// BRANCHES heading with an inline "Fetch" button on the right.
    /// Tapping runs `git fetch --all --prune` and reloads — the
    /// REMOTES list (rendered just below the local branches inside
    /// the same scroll view) picks up newly-pushed refs without
    /// the user having to hunt for the footer's fetch glyph.
    private var branchesHeader: some View {
        HStack(spacing: 6) {
            Text("BRANCHES")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.fetch()
            } label: {
                HStack(spacing: 3) {
                    if store.busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10))
                    }
                    Text("Fetch")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(store.busy)
            .help("git fetch --all --prune — pick up new remote branches")
        }
        .padding(.horizontal, 14)
    }

    /// Sub-heading inside the same scroll view, separating remote
    /// branches from the local ones above. Kept lighter than the
    /// section labels so it reads as a sub-group, not a peer.
    private func remotesSubheader(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("REMOTES (\(count))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func branchRow(_ name: String, current: Bool) -> some View {
        Button {
            guard !current else { return }
            store.switchBranch(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(current ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(current ? "Currently on \(name)" : "Switch to \(name)")
    }

    /// Remote branch row. Tap to create a local tracking branch
    /// (`git switch --track <remote>`) and check it out — the same
    /// muscle-memory as the local branch row, just with a cloud
    /// glyph and a fainter color to read as "not yet local."
    private func remoteBranchRow(_ name: String) -> some View {
        Button {
            store.checkoutRemote(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Check out \(name) as a local tracking branch")
    }

    /// Small "← Follow current focus" pill shown at the top of
    /// content when the user has pinned to a saved project. Tap to
    /// clear the pin and resume focus-following.
    private var followFocusBanner: some View {
        Button {
            store.returnToFocus()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Following saved project")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text("Follow focus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop pinning this project; resume tracking focused window")
    }

    private func savedRow(_ p: WorktreeStore.SavedProject,
                          currentPath: String) -> some View {
        let isCurrent = p.path == currentPath
        return Button {
            store.viewSaved(p)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCurrent
                      ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10))
                    .foregroundStyle(isCurrent
                                     ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let b = p.lastKnownBranch {
                        Text(b)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrent
              ? "Currently viewing \(p.displayName)"
              : "Switch to \(p.displayName)")
        .contextMenu {
            Button("Remove from saved", role: .destructive) {
                store.removeSaved(p)
            }
        }
    }

    private func worktreeRow(_ w: WorktreeStore.WorktreeEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: w.isCurrent
                  ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(w.isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(URL(fileURLWithPath: w.path).lastPathComponent
                     + (w.isMain ? " (main)" : ""))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let b = w.branch {
                    Text(b)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: w.path))
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            gitGlyph(size: 22)
                .foregroundStyle(.tertiary)
            Text("Not in a git repo")
                .font(.system(size: 12, weight: .medium))
            Text("Focus a window in a repo (Xcode, VS Code, "
                 + "Terminal, …) and Worktree will pick it up.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                showingNewBranch = true
                newBranchName = ""
            } label: {
                Label("Branch", systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(store.current == nil)

            Button {
                showingNewWorktree = true
                worktreeBranchName = ""
                worktreePath = ""
                worktreeCreateNew = true
            } label: {
                Label("Worktree", systemImage: "square.split.bottomrightquarter")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(store.current == nil)

            Spacer()

            if store.busy {
                ProgressView().controlSize(.small)
            }

            Button {
                store.fetch()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("git fetch --all")
            .disabled(store.current == nil || store.busy)

            Button {
                store.pull()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("git pull --ff-only")
            .disabled(store.current == nil || store.busy)

            Menu {
                Button("Quit Worktree") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sheets

    private var newBranchSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New branch")
                .font(.system(size: 14, weight: .semibold))
            TextField("name (e.g. feat/preset-picker)",
                      text: $newBranchName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingNewBranch = false }
                Button("Create") {
                    store.createBranch(newBranchName)
                    showingNewBranch = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func newWorktreeSheet(_ snap: WorktreeStore.RepoSnapshot)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Text("New worktree")
                .font(.system(size: 14, weight: .semibold))
            Text("Adds a linked working directory checked out to "
                 + "a chosen branch — switch branches without "
                 + "stashing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Create new branch", isOn: $worktreeCreateNew)

            TextField(
                worktreeCreateNew
                    ? "new branch name"
                    : "existing branch name",
                text: $worktreeBranchName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("path (absolute)", text: $worktreePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(
                        fileURLWithPath: snap.path)
                        .deletingLastPathComponent()
                    if panel.runModal() == .OK,
                       let url = panel.url {
                        worktreePath = url.path
                    }
                }
            }

            if worktreePath.isEmpty {
                Text("Suggested: \(snap.path)-\(worktreeBranchName.isEmpty ? "<branch>" : worktreeBranchName)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { showingNewWorktree = false }
                Button("Create") {
                    let p = worktreePath.isEmpty
                        ? "\(snap.path)-\(worktreeBranchName)"
                        : worktreePath
                    store.createWorktree(
                        branchName: worktreeBranchName,
                        createNew: worktreeCreateNew,
                        atPath: p)
                    showingNewWorktree = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(worktreeBranchName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

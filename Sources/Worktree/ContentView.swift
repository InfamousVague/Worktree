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
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
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
            // Repo + branch summary
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
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

            // Branches list (scrollable when long)
            sectionLabel("BRANCHES")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snap.localBranches, id: \.self) { name in
                        branchRow(name, current: name == snap.branch)
                    }
                }
            }
            .frame(maxHeight: 180)

            Divider()

            // Worktrees list
            sectionLabel("WORKTREES (\(snap.worktrees.count))")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snap.worktrees) { w in
                    worktreeRow(w)
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
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
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

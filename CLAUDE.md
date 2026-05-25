# worktree

Menu-bar agent that shows the git repo + branch the user is
currently editing, plus a popover to switch branches and manage
`git worktree` instances. Detects the active project by inspecting
the frontmost macOS app's focused window (Xcode, VS Code-family,
Terminal-family) and falling back to reading the frontmost
process's CWD.

## Commit Convention
Angular commits with scope. See @.claude/rules/commit-rules.md.

## Code Style
See @.claude/rules/code-style.md.

## Architecture

- `Sources/Worktree/WorktreeApp.swift` — `@main` SwiftUI App +
  `@MainActor AppDelegate` (NSStatusItem variable-length + NSPopover,
  `LSUIElement` agent).
- `Sources/Worktree/Models.swift` —
  `@MainActor @Observable WorktreeStore`: current repo snapshot
  (sticky on non-coding apps), focus-change observer, async fetch /
  pull, write ops that reload after success.
- `Sources/Worktree/ContextResolver.swift` — adapter chain that
  maps a frontmost app to "which folder is the user editing":
  - `XcodeAdapter` — AppleScript `path of active workspace document`
  - `VSCodeAdapter` — `--folder-uri=` on the renderer cmdline +
    AX focused-window-title fallback. Covers VS Code / Cursor /
    Windsurf / Code-OSS.
  - `TerminalAdapter` — deepest descendant's CWD via `proc_pidinfo`.
    Covers Terminal / iTerm2 / Ghostty / Hyper / Warp / Alacritty /
    Kitty / Wezterm / Tabby / Zed embedded shell.
  - `GenericCWDAdapter` — last-ditch CWD of the frontmost process.
- `Sources/Worktree/ProcessInfo.swift` — BSD `proc_pidinfo` wrapper
  (CWD lookup + child-tree BFS) and `KERN_PROCARGS2` sysctl wrapper
  (argv read for VS Code-family).
- `Sources/Worktree/GitOps.swift` — shell-out to `/usr/bin/git`,
  `Result`-returning, parses porcelain output for `status` and
  `worktree list`.
- `Sources/Worktree/ContentView.swift` — 320pt popover UI: repo
  header, branches list, worktrees list, create-branch sheet,
  add-worktree sheet, fetch / pull footer buttons.

## Running

```
xcodegen generate            # one-time after cloning
open Worktree.xcodeproj      # iterate from Xcode
bash scripts/make-app.sh     # produce signed Worktree.app + .dmg
```

## Permissions
On first run Worktree prompts for:
- **Accessibility** — required to read the focused window title in
  VS Code-family adapters (`AXUIElementCopyAttributeValue`).
- **AppleEvents → Xcode** — required for the Xcode adapter's
  AppleScript dictionary call.

Both are optional in the sense that the app degrades gracefully
when denied (terminal + generic CWD adapters still work).

## Why shell out to /usr/bin/git instead of linking libgit2
This is a menu-bar utility — git ops happen at user-click rate, so
fork/exec cost is negligible (~3ms). Shelling lets us support
whatever the user has installed (Apple CLT git, homebrew git, fork
variants) with zero ABI surface area. The same trade-off the rest
of the suite makes.

# Code Style

- Follow the project's existing patterns (mirror `seasick-swift` /
  `port-swift`).
- Keep functions focused; prefer explicit over implicit.
- UI state lives in `WorktreeStore` (`@MainActor`, `@Observable`);
  views stay declarative.
- AX / AppleScript / BSD `proc_pidinfo` live in their own files
  (`ContextResolver.swift`, `ProcessInfo.swift`); the SwiftUI layer
  doesn't import `ApplicationServices` or call `proc_pidinfo`
  directly.
- Git shell-outs go through `GitOps`; nothing else spawns
  `Process` for git work.
- The menu-bar item must never block the main actor on a git op —
  fetch / pull dispatch to a background `Task.detached` and flip a
  `busy` flag on the store while in flight.
- Sticky-snapshot rule: when the resolver can't find a repo
  (user focused Mail, Slack, etc.), keep showing the last-known
  repo rather than blanking the menu bar.

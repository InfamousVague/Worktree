import AppKit
import ApplicationServices
import Foundation

/// "Which folder is the user currently working in?" — the
/// pipeline that powers Worktree's menu bar indicator.
///
/// Inputs: the frontmost macOS app + its focused window.
/// Outputs: an absolute filesystem path the caller walks up to
/// find `.git`.
///
/// Strategy is a chain of per-app adapters; the first one that
/// matches the frontmost app's bundle id returns its best guess.
/// If none match, falls back to reading the frontmost process's
/// CWD via `proc_pidinfo`.
@MainActor
final class ContextResolver {
    private let adapters: [ContextAdapter] = [
        XcodeAdapter(),
        VSCodeAdapter(),     // also handles Cursor, Windsurf — same bundle id family
        TerminalAdapter(),   // Terminal.app, iTerm2, Ghostty, Warp, …
        GenericCWDAdapter(), // catch-all fallback
    ]

    /// The last activated app whose bundle id wasn't ours.
    ///
    /// Why we need this: clicking Worktree's status-bar item makes
    /// AppKit activate Worktree, so `NSWorkspace.frontmostApplication`
    /// suddenly returns Worktree itself — useless for resolving
    /// "which folder is the user editing." We watch activation
    /// events and remember the most recent foreign app so popover
    /// opens (and any subsequent refresh) still resolve against
    /// whatever the user was actually working in.
    private var lastForeignApp: NSRunningApplication?
    private var foreignAppObserver: NSObjectProtocol?
    private let selfBundleID: String? = Bundle.main.bundleIdentifier

    init() {
        // Seed with whatever's frontmost right now (in case it's
        // already a useful app on launch).
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != selfBundleID {
            lastForeignApp = app
        }
        foreignAppObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.bundleIdentifier != self.selfBundleID
                else { return }
                Task { @MainActor in self.lastForeignApp = app }
            }
    }

    deinit {
        if let o = foreignAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    /// Best-effort path for the current focused window. Returns
    /// nil only if no adapter could come up with anything — the
    /// caller should hold on to the previous result and keep the
    /// menu-bar indicator stable rather than blanking out.
    func currentPath() -> String? {
        guard let app = currentForeignApp(),
              let bundleID = app.bundleIdentifier else {
            return nil
        }
        for adapter in adapters where adapter.matches(bundleID: bundleID) {
            if let p = adapter.resolve(app: app), !p.isEmpty {
                return p
            }
        }
        // No adapter claimed this app — last-ditch CWD read.
        return GenericCWDAdapter().resolve(app: app)
    }

    /// Stricter variant: only returns a path if the frontmost
    /// app is verified-editor (Xcode, VS Code-family, terminal
    /// emulators). Skips the GenericCWDAdapter fallback so
    /// non-editor focus changes (Mail, Slack, Spotify) don't
    /// move the Worktree indicator — the previous snapshot
    /// stays sticky.
    func currentEditorPath() -> String? {
        guard let app = currentForeignApp(),
              let bundleID = app.bundleIdentifier else {
            return nil
        }
        for adapter in adapters where adapter.matches(bundleID: bundleID) {
            if let p = adapter.resolve(app: app), !p.isEmpty {
                return p
            }
        }
        return nil   // editor adapter didn't claim → no update
    }

    /// Prefer the last activated foreign app — that's "what the
    /// user was working in before they clicked our menu bar."
    /// Fall back to frontmostApplication if we somehow haven't
    /// seen an activation yet AND the current frontmost isn't us.
    private func currentForeignApp() -> NSRunningApplication? {
        if let last = lastForeignApp { return last }
        let front = NSWorkspace.shared.frontmostApplication
        return front?.bundleIdentifier == selfBundleID ? nil : front
    }
}

// MARK: - Adapter protocol

/// `@MainActor` because `VSCodeAdapter` reaches for the
/// Accessibility API (focused window title), which is only safe
/// from the main actor on macOS. The other adapters don't strictly
/// need it, but constraining the whole protocol keeps `ContextResolver`'s
/// dispatch loop free of per-adapter actor hops.
@MainActor
protocol ContextAdapter {
    /// Bundle id match — keep this cheap, it's called per-focus-change.
    func matches(bundleID: String) -> Bool
    /// Return the best path you can find for the focused window in
    /// this app's frontmost state. Return nil if you can't tell.
    func resolve(app: NSRunningApplication) -> String?
}

// MARK: - Xcode

/// Uses Xcode's AppleScript dictionary: `path of active workspace
/// document` returns the absolute .xcworkspace / .xcodeproj path.
/// One-time TCC prompt the first time we run an AE event against
/// Xcode (Info.plist's NSAppleEventsUsageDescription explains the
/// ask).
struct XcodeAdapter: ContextAdapter {
    func matches(bundleID: String) -> Bool {
        bundleID == "com.apple.dt.Xcode"
    }

    func resolve(app: NSRunningApplication) -> String? {
        let source = """
        tell application "Xcode"
            if (count of workspace documents) > 0 then
                return path of active workspace document
            else
                return ""
            end if
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let path = result.stringValue ?? ""
        guard !path.isEmpty else { return nil }
        // Strip the .xcworkspace / .xcodeproj — we want the
        // containing directory (where .git lives).
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "xcworkspace" || url.pathExtension == "xcodeproj" {
            return url.deletingLastPathComponent().path
        }
        return path
    }
}

// MARK: - VS Code family (Cursor, Windsurf, Code-OSS forks)

/// Three-stage strategy, in order of reliability:
///
/// 1. **Storage file** (primary): every VS Code-family app keeps
///    `~/Library/Application Support/<AppDir>/User/globalStorage/storage.json`
///    where `windowsState.lastActiveWindow.folder` is the URI of
///    the most-recently-focused folder — exactly what we want.
///    Updates whenever the user opens a folder or switches windows,
///    so it tracks live state.
///
/// 2. **Renderer cmdline**: when the user launched the editor from
///    the terminal as `code path/`, the path shows up on a renderer
///    process's argv as `--folder-uri=…`. Useful for the "opened
///    from CLI, never used File → Open" case.
///
/// 3. **AX window title**: parse the focused window's title bar
///    (default format ends in the folder name) and cross-reference
///    with the multi-window list from storage.json. This
///    disambiguates when the user has several windows open.
struct VSCodeAdapter: ContextAdapter {
    /// Bundle id → application support subdirectory. The
    /// subdirectory holds `User/globalStorage/storage.json`.
    /// Add new forks here as they show up — the storage layout is
    /// inherited from upstream VS Code so the same parser works.
    private static let bundleIDToSupportDir: [String: String] = [
        "com.microsoft.VSCode":          "Code",
        "com.microsoft.VSCodeInsiders":  "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",        // Cursor
        "com.exafunction.windsurf":      "Windsurf",
        "com.visualstudio.code.oss":     "Code - OSS",
    ]

    func matches(bundleID: String) -> Bool {
        Self.bundleIDToSupportDir[bundleID] != nil
    }

    func resolve(app: NSRunningApplication) -> String? {
        // 1) Storage file (most reliable — covers File → Open and
        // workspace recents, not just CLI launches).
        if let bid = app.bundleIdentifier,
           let supportDir = Self.bundleIDToSupportDir[bid] {
            if let path = Self.pathFromStorage(supportDir: supportDir,
                                               pid: app.processIdentifier) {
                return path
            }
        }

        // 2) Descendant cmdline walk (for CLI-launched windows
        // whose storage.json hasn't picked up the new folder yet).
        let descendants = ProcessIntrospection.descendants(of: app.processIdentifier)
        var folderURIs: Set<String> = []
        for pid in descendants {
            let cmd = ProcessIntrospection.commandLine(of: pid)
            if let uri = Self.extractFolderURI(from: cmd) {
                folderURIs.insert(uri)
            }
        }
        if folderURIs.count == 1, let only = folderURIs.first {
            return Self.pathFromFileURI(only)
        }

        // 3) AX title fallback (cross-referenced with whatever URIs
        // we collected).
        if let title = focusedWindowTitle(for: app.processIdentifier),
           let path = Self.pathFromTitle(title, folderURIs: folderURIs) {
            return path
        }

        return nil
    }

    // MARK: Storage-file strategy

    /// Read `~/Library/Application Support/<supportDir>/User/globalStorage/storage.json`
    /// and return the best matching folder URI.
    ///
    /// Single-window case: `windowsState.lastActiveWindow.folder`.
    /// Multi-window case: cross-reference the AX focused window
    /// title against `windowsState.openedWindows[].folder` by
    /// matching the last path component (= folder display name).
    private static func pathFromStorage(supportDir: String,
                                        pid: pid_t) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storage = home
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(supportDir)
            .appendingPathComponent("User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: storage),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any],
              let windowsState = dict["windowsState"] as? [String: Any]
        else { return nil }

        // Collect candidate URIs + their order. lastActiveWindow is
        // the most-recently-focused one, so put it first.
        var candidates: [String] = []
        if let last = windowsState["lastActiveWindow"] as? [String: Any],
           let f = last["folder"] as? String { candidates.append(f) }
        if let opened = windowsState["openedWindows"] as? [[String: Any]] {
            for w in opened {
                if let f = w["folder"] as? String, !candidates.contains(f) {
                    candidates.append(f)
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // If only one folder is tracked, we're done.
        if candidates.count == 1, let only = candidates.first {
            return pathFromFileURI(only)
        }

        // Multi-window: use the focused-window title to pick the
        // right one. VS Code's default title ends with the folder
        // name (separator is em-dash).
        if let title = focusedWindowTitle(for: pid) {
            let lastSegment = titleTrailingSegment(title)
            for uri in candidates {
                guard let p = pathFromFileURI(uri) else { continue }
                if URL(fileURLWithPath: p).lastPathComponent
                    .caseInsensitiveCompare(lastSegment) == .orderedSame {
                    return p
                }
            }
        }

        // No disambiguation available — fall back to the most
        // recently focused one. Better to point at *something*
        // plausible than nothing.
        return pathFromFileURI(candidates[0])
    }

    // MARK: Cmdline-walk strategy (secondary)

    /// Match `--folder-uri=file:///...` (one of several VS Code
    /// CLI knobs). Also matches `--file-uri=` for the open-file
    /// case (we can walk up to the repo root from a file path).
    private static func extractFolderURI(from cmd: String) -> String? {
        for prefix in ["--folder-uri=", "--file-uri="] {
            if let r = cmd.range(of: prefix) {
                let tail = cmd[r.upperBound...]
                let uri = tail.split(separator: " ").first.map(String.init) ?? ""
                return uri.isEmpty ? nil : uri
            }
        }
        return nil
    }

    private static func pathFromFileURI(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let raw = String(uri.dropFirst("file://".count))
        return raw.removingPercentEncoding
    }

    // MARK: Title-parse strategy (tertiary)

    /// Cross-reference the focused window's title bar with the set
    /// of folder URIs we discovered on the command line. Title
    /// formats vary; default is "<file> — <folderName>" (em-dash).
    private static func pathFromTitle(_ title: String,
                                      folderURIs: Set<String>) -> String? {
        let lastSegment = titleTrailingSegment(title)
        guard !lastSegment.isEmpty else { return nil }
        for uri in folderURIs {
            if let path = pathFromFileURI(uri),
               URL(fileURLWithPath: path).lastPathComponent
                .caseInsensitiveCompare(lastSegment) == .orderedSame {
                return path
            }
        }
        return nil
    }

    /// Split on the common separators VS Code uses in window
    /// titles and return whatever's after the last one. For the
    /// default title format this is the folder name.
    private static func titleTrailingSegment(_ title: String) -> String {
        let separators: [Character] = ["—", "–", "-", "|"]
        for sep in separators {
            if let idx = title.lastIndex(of: sep) {
                return String(title[title.index(after: idx)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Terminal family

/// Read the CWD of the deepest descendant of the terminal's main
/// process. That catches the active shell, including a `vim` /
/// `nvim` running inside it (since vim inherits + maintains the
/// shell's CWD, walking deeper still lands on a sensible path).
struct TerminalAdapter: ContextAdapter {
    private static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.warp.dev.warp",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.rivendell.tabby",
        "dev.zed.Zed",      // Zed's not a terminal but its terminal-app behaviour fits here for the embedded shell
    ]

    func matches(bundleID: String) -> Bool {
        Self.bundleIDs.contains(bundleID)
    }

    func resolve(app: NSRunningApplication) -> String? {
        let parent = app.processIdentifier
        let descendants = ProcessIntrospection.descendants(of: parent)
        // Try each descendant from deepest first — the user's
        // shell (and anything they've launched inside it) tends
        // to live further down the tree than the terminal's
        // helper processes.
        for pid in descendants.reversed() {
            if let cwd = ProcessIntrospection.cwd(of: pid),
               cwd != "/" && cwd != "/private/tmp" {
                return cwd
            }
        }
        // Last resort: the terminal app process itself.
        return ProcessIntrospection.cwd(of: parent)
    }
}

// MARK: - Generic fallback

/// When no per-app adapter knows what to do, just read the
/// frontmost process's CWD. Many native macOS apps don't set a
/// meaningful CWD (it's `/` or wherever launchd left them), so
/// this only fires usefully for command-line tools running under
/// any shell.
struct GenericCWDAdapter: ContextAdapter {
    func matches(bundleID: String) -> Bool { true }

    func resolve(app: NSRunningApplication) -> String? {
        let cwd = ProcessIntrospection.cwd(of: app.processIdentifier)
        // Filter out trivial CWDs that won't lead anywhere.
        guard let cwd, cwd != "/", !cwd.hasPrefix("/System") else {
            return nil
        }
        return cwd
    }
}

// MARK: - Accessibility helpers

/// Return the focused window's title for the given app's PID via
/// the AX API. Requires Accessibility permission (one-time TCC
/// prompt — the AX init will hold the focused-window lookup until
/// the user grants).
@MainActor
private func focusedWindowTitle(for pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var focused: AnyObject?
    let r = AXUIElementCopyAttributeValue(
        app,
        kAXFocusedWindowAttribute as CFString,
        &focused
    )
    guard r == .success, let window = focused else { return nil }
    var title: AnyObject?
    let r2 = AXUIElementCopyAttributeValue(
        window as! AXUIElement,
        kAXTitleAttribute as CFString,
        &title
    )
    guard r2 == .success else { return nil }
    return title as? String
}

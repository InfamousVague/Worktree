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

    /// Best-effort path for the current focused window. Returns
    /// nil only if no adapter could come up with anything — the
    /// caller should hold on to the previous result and keep the
    /// menu-bar indicator stable rather than blanking out.
    func currentPath() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
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

/// Two-stage strategy:
///
/// 1. Look at the main process's command line — when VS Code is
///    launched on a folder it gets `code /path/to/folder` or
///    `--folder-uri=file:///...`. Reliable when there's exactly
///    one window; ambiguous with multiple windows on different
///    folders (the main process is shared).
///
/// 2. Fall back to parsing the focused window's title bar via
///    Accessibility. Default VS Code title format ends with the
///    folder name; users who customize it harder are on their own.
struct VSCodeAdapter: ContextAdapter {
    private static let bundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.visualstudio.code.oss",
    ]

    func matches(bundleID: String) -> Bool {
        Self.bundleIDs.contains(bundleID)
    }

    func resolve(app: NSRunningApplication) -> String? {
        // 1) Walk descendants — VS Code-family apps spawn one
        // renderer per window, and the workspace path appears on
        // the renderer's argv as `--folder-uri=…` or as a tail
        // positional. We can't tell which renderer maps to the
        // FOCUSED window without an extension, so this only
        // succeeds when exactly one folder is open across all
        // windows (the common single-window case).
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

        // 2) Title-bar parse via Accessibility.
        if let title = focusedWindowTitle(for: app.processIdentifier),
           let path = Self.pathFromTitle(title, folderURIs: folderURIs) {
            return path
        }

        return nil
    }

    /// Match `--folder-uri=file:///...` (one of several VS Code
    /// CLI knobs). Also matches a bare positional path appearing
    /// after `code` — rarer but worth a try.
    private static func extractFolderURI(from cmd: String) -> String? {
        if let r = cmd.range(of: "--folder-uri=") {
            let tail = cmd[r.upperBound...]
            let uri = tail.split(separator: " ").first.map(String.init) ?? ""
            return uri.isEmpty ? nil : uri
        }
        if let r = cmd.range(of: "--file-uri=") {
            let tail = cmd[r.upperBound...]
            let uri = tail.split(separator: " ").first.map(String.init) ?? ""
            return uri.isEmpty ? nil : uri
        }
        return nil
    }

    private static func pathFromFileURI(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let raw = String(uri.dropFirst("file://".count))
        return raw.removingPercentEncoding
    }

    /// Cross-reference the focused window's title bar with the set
    /// of folder URIs we discovered on the command line. Title
    /// formats vary; default is "<file> — <folderName>" (em-dash).
    private static func pathFromTitle(_ title: String,
                                      folderURIs: Set<String>) -> String? {
        // Split on common separators VS Code uses in window titles.
        let separators: [Character] = ["—", "–", "-", "|"]
        let lastSegment: String = {
            for sep in separators {
                if let idx = title.lastIndex(of: sep) {
                    return String(title[title.index(after: idx)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return title.trimmingCharacters(in: .whitespaces)
        }()
        guard !lastSegment.isEmpty else { return nil }
        // Match folder URIs by basename. Folders sharing a basename
        // (e.g. two projects both named `app`) stay ambiguous —
        // those users will need the future Worktree-companion
        // extension for 100% accuracy.
        for uri in folderURIs {
            if let path = pathFromFileURI(uri),
               URL(fileURLWithPath: path).lastPathComponent == lastSegment {
                return path
            }
        }
        return nil
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

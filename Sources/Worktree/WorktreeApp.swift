import AppKit
import ApplicationServices
import SwiftUI

/// Entry point. SwiftUI's @main is the cleanest way to bootstrap
/// an `LSUIElement` agent these days; we still need an
/// `AppDelegate` to own the `NSStatusItem` + `NSPopover` because
/// SwiftUI's `MenuBarExtra` doesn't let us update the status bar
/// title dynamically (it's all-symbol-or-all-text — we want both,
/// branch name beside the icon).
@main
struct WorktreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Empty Settings scene keeps SwiftUI happy without spawning
        // a main window. The status item + popover live entirely on
        // the AppDelegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WorktreeStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover!
    private var snapshotObservation: NSKeyValueObservation?

    // Worktree's menu-bar status item is always shown — the
    // earlier "hide when Halo is running" behaviour gave the
    // user no way back into the popover when Halo couldn't
    // open it on their behalf. Halo's island can coexist with
    // our icon; users who don't want both can quit Worktree
    // outright from the launcher.

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItemIfNeeded()

        // Popover holds the SwiftUI ContentView. Transient = closes
        // when the user clicks outside, which is the menu-bar UX
        // people expect from this kind of app.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environment(store)
        )

        // Subscribe to store changes by polling on a tiny tick.
        // SwiftUI's @Observable doesn't bridge cleanly to KVO; the
        // status bar title just reads `store.current` directly each
        // tick. 1 Hz is plenty — `current` only changes on focus
        // change or a manual op. Same tick also rechecks Halo's
        // running state so the status item appears/disappears
        // when Halo launches or quits.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.installStatusItemIfNeeded()
                self?.updateStatusBarTitle()
            }
        }

        // NB: we deliberately don't fire AXIsProcessTrustedWithOptions
        // at launch any more. With the suite shipping ad-hoc /
        // signed-and-re-signed builds during development, TCC sometimes
        // treats each rebuild as a fresh identity and the prompt
        // re-appears every launch — annoying even when the user has
        // already granted access. Worktree's resolver chain still works
        // without AX (terminals + Xcode AppleScript don't need it),
        // and the VS Code-family adapter degrades gracefully when AX
        // is denied. Users can grant via System Settings or via the
        // "Grant Accessibility" row in the popover footer.

        store.start()
        updateStatusBarTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: - UI

    /// Install Worktree's status item once at launch. Always
    /// shown — Halo's island is a secondary surface, the menu-
    /// bar icon is the primary way to reach the popover (and
    /// to confirm Worktree is actually running).
    private func installStatusItemIfNeeded() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            // Official Git logo (CC BY 3.0, Jason Long) bundled
            // at Resources/MenuBarIcon.png — see NOTICE for
            // attribution. Fall back to the SF Symbol if the
            // asset is missing so the button never renders
            // empty.
            let menuBarImage = NSImage(named: "MenuBarIcon") ?? NSImage(
                systemSymbolName: "arrow.triangle.branch",
                accessibilityDescription: "Worktree"
            )
            menuBarImage?.size = NSSize(width: 18, height: 18)
            menuBarImage?.isTemplate = true
            item.button?.image = menuBarImage
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        }
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem?.button else { return }
        if let snap = store.current {
            // Truncate long branch names so the menu bar doesn't
            // get hijacked by a 60-char feature/foo-bar-baz branch.
            let branch = snap.branch.count > 20
                ? String(snap.branch.prefix(18)) + "…"
                : snap.branch
            button.title = " " + branch
            button.toolTip = "\(snap.displayName) — \(snap.branch)"
        } else {
            button.title = ""
            button.toolTip = "Worktree — focus a coding window"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Refresh the moment we open so the popover always reflects
        // the current focus (the user may have switched apps since
        // the last tick).
        store.refreshFromFocus()
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        // Force the popover to take key window so its text fields
        // can accept input on first click — without this, the first
        // click is consumed by .makeKey and the second registers.
        popover.contentViewController?.view.window?.makeKey()
    }
}

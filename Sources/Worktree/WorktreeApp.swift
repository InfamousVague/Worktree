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
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var snapshotObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status item: variable-length so the title can grow with
        // the branch name. We set both an SF Symbol image and a
        // text title; AppKit renders them side-by-side.
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        // Official Git logo (CC BY 3.0, Jason Long) bundled at
        // Resources/MenuBarIcon.png — see NOTICE for attribution.
        // Fall back to the SF Symbol if the asset is missing for
        // some reason so the button never renders empty.
        let menuBarImage = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Worktree"
        )
        // Scale the asset down to the menu-bar's expected ~18pt
        // height. Without this, the 1024×1024 source PNG dominates
        // the bar.
        menuBarImage?.size = NSSize(width: 18, height: 18)
        menuBarImage?.isTemplate = true
        statusItem.button?.image = menuBarImage
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

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
        // change or a manual op.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusBarTitle() }
        }

        // Request Accessibility on first launch. Worktree needs it
        // to read the focused-window title in VS Code-family apps —
        // without AX, multi-window setups can't be disambiguated
        // (storage.json lists all open windows but doesn't say
        // which one is currently focused). The prompt is one-time;
        // macOS remembers the user's answer.
        let opts: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)

        store.start()
        updateStatusBarTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: - UI

    private func updateStatusBarTitle() {
        guard let button = statusItem.button else { return }
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
        guard let button = statusItem.button else { return }
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

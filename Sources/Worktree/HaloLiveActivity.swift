import Foundation

/// On-disk payload shape that Halo (the MattsSoftware Dynamic
/// Island agent) reads from `~/Library/Application Support/
/// MattsSoftware/live-activity/<id>.json`.
///
/// We don't link SuiteKit just for this — Worktree is a
/// standalone agent shipped as its own `.app`, and the payload
/// format is dead simple. Halo's coordinator polls the
/// directory at 1 Hz and treats anything older than 30s as
/// stale, so the worst-case "Worktree crashed without
/// clearing" is a pill that hangs around for half a minute.
struct HaloLiveActivityPayload: Codable {
    var compactLeadingSymbol: String?
    var compactTrailingText: String?
    var compactTrailingSymbol: String?
    var tintHex: String
    var priority: Int
    var updatedAt: TimeInterval
    /// Optional worktree-specific extras — populated only by
    /// Worktree publishes, ignored by Halo for other ids.
    var worktree: WorktreeData?
}

/// Full state payload for Halo's Worktree expanded card. Every
/// section the standalone Worktree popover renders is
/// represented here so Halo can act as a complete control
/// surface without re-running git ops itself. Newer fields are
/// all defaulted so older Halo decoders that don't know about
/// them don't crash.
struct WorktreeData: Codable {
    var repoPath: String
    var displayName: String?
    var currentBranch: String
    var branches: [String]
    var remoteBranches: [String] = []
    var isDirty: Bool
    var ahead: Int = 0
    var behind: Int = 0
    var dirtyCount: Int = 0
    var worktrees: [WorktreeEntryData] = []
    var savedProjects: [SavedProjectData] = []
    var isPinned: Bool = false
    var lastError: String?
}

struct WorktreeEntryData: Codable, Hashable {
    var path: String
    var branch: String?
    var isCurrent: Bool
    var isMain: Bool
}

struct SavedProjectData: Codable, Hashable {
    var path: String
    var displayName: String
    var lastKnownBranch: String?
}

// MARK: - Command channel

/// One inbound command from Halo. Worktree polls
/// `worktree.commands.json` for these and dispatches via
/// `WorktreeStore`. The `id` is a UUID string — Worktree tracks
/// processed ids in-memory to avoid double-execution on retries
/// or stale-file reads.
///
/// `action` is a stable string identifier. Defined cases:
///   "switchBranch"     branch
///   "createBranch"     branch
///   "fetch"            —
///   "pull"             —
///   "checkoutRemote"   ref
///   "toggleSaveCurrent" —
///   "viewSaved"        path
///   "returnToFocus"    —
///   "removeSaved"      path
///   "addWorktree"      branch + createNew + path
///   "openInFinder"     path
struct WorktreeCommand: Codable, Identifiable, Equatable {
    var id: String
    var action: String
    var branch: String?
    var ref: String?
    var path: String?
    var createNew: Bool?
    var submittedAt: TimeInterval
}

struct WorktreeCommandQueue: Codable {
    var commands: [WorktreeCommand]
    var updatedAt: TimeInterval
}

/// Thin wrapper around the JSON write/clear path. Mirrors
/// `SuiteLiveActivityStore`'s API so the call sites read the
/// same as Espresso / Port / Peephole.
enum HaloLiveActivityWriter {
    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        let dir = base
            .appendingPathComponent("MattsSoftware", isDirectory: true)
            .appendingPathComponent("live-activity", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func write(_ payload: HaloLiveActivityPayload, for id: String) {
        let url = directory.appendingPathComponent("\(id).json")
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            // Push notification so Halo re-polls immediately
            // rather than waiting up to a polling interval —
            // makes repo / branch switches feel instant.
            DistributedNotificationCenter.default()
                .postNotificationName(
                    Notification.Name("com.mattssoftware.halo.refresh"),
                    object: nil,
                    deliverImmediately: true)
        } catch {
            NSLog("Worktree: live-activity write failed for \(id): \(error)")
        }
    }

    static func clear(_ id: String) {
        let url = directory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name("com.mattssoftware.halo.refresh"),
                object: nil,
                deliverImmediately: true)
    }
}

/// Drain side of the command channel — read what Halo has
/// queued, then write back only the commands Worktree hasn't
/// processed yet. Atomic writes; the natural race with Halo's
/// appendCommand at 1 Hz is rare enough that processed-id
/// dedup handles the duplicate cases.
enum HaloCommandReader {
    static func commandsURL(for id: String) -> URL {
        HaloLiveActivityWriter.directory
            .appendingPathComponent("\(id).commands.json")
    }

    static func read(for id: String) -> WorktreeCommandQueue {
        let url = commandsURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode(
                WorktreeCommandQueue.self, from: data)
        else { return WorktreeCommandQueue(commands: [],
                                            updatedAt: 0) }
        return queue
    }

    /// Write a new queue (typically the remainder after drain).
    static func write(_ queue: WorktreeCommandQueue, for id: String) {
        let url = commandsURL(for: id)
        do {
            let data = try JSONEncoder().encode(queue)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Worktree: command-queue write failed: \(error)")
        }
    }
}

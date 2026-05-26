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
}

/// Thin wrapper around the JSON write/clear path. Mirrors
/// `SuiteLiveActivityStore`'s API so the call sites read the
/// same as Espresso / Port / Peephole.
enum HaloLiveActivityWriter {
    private static let directory: URL = {
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

import Darwin
import Foundation

/// Thin wrapper around the `proc_pidinfo` BSD API for reading a
/// running process's current working directory + walking the
/// process tree to find the deepest descendant. The CWD walk is
/// how Worktree finds "which folder is the user actually editing"
/// when the frontmost app is a terminal — the terminal's own CWD
/// is irrelevant; we want the shell child's CWD.
///
/// Lives outside any per-app adapter because the same technique
/// is the generic fallback for any process that has a meaningful
/// CWD but no AppleScript dictionary + no parseable command-line
/// hint (e.g. Vim run directly under `bash` in iTerm2).
enum ProcessIntrospection {
    /// Read the CWD of `pid` via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
    /// Returns nil if the process has gone away or has no CWD
    /// (kernel threads, some launchd-spawned daemons).
    static func cwd(of pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &vpi,
            Int32(size)
        )
        guard result > 0 else { return nil }
        // pvi_cdir.vip_path is a fixed-length C array of CChar; bridge
        // it through a Swift String by walking until the NUL terminator.
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) { ptr -> String? in
            let cString = UnsafeRawPointer(ptr)
                .assumingMemoryBound(to: CChar.self)
            let s = String(cString: cString)
            return s.isEmpty ? nil : s
        }
    }

    /// Every direct + transitive child PID of `parent`, in BFS order.
    /// Implemented by listing all PIDs once and partitioning by
    /// parent — cheaper than spawning `pgrep` for each level.
    static func descendants(of parent: pid_t) -> [pid_t] {
        // First pass: a `pid → ppid` map over every visible process.
        // PROC_ALL_PIDS with a nil buffer returns the size needed.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let written = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        let live = Array(pids.prefix(Int(written))).filter { $0 > 0 }

        // Build the ppid map by reading bsdinfo on each.
        var parentOf: [pid_t: pid_t] = [:]
        for pid in live {
            var info = proc_bsdinfo()
            let r = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            if r > 0 { parentOf[pid] = pid_t(info.pbi_ppid) }
        }

        // BFS from `parent` outward.
        var result: [pid_t] = []
        var frontier: [pid_t] = [parent]
        while !frontier.isEmpty {
            let next = frontier
            frontier.removeAll(keepingCapacity: true)
            for childPid in live where next.contains(parentOf[childPid] ?? -1) {
                result.append(childPid)
                frontier.append(childPid)
            }
        }
        return result
    }

    /// The full command line of `pid` (argv joined with spaces).
    /// Used by VS Code-family adapters to pull `--folder-uri=…` out
    /// of the renderer process args. Falls back to empty string on
    /// permission denial or missing process.
    ///
    /// Implementation note: macOS ships an undocumented sysctl
    /// `KERN_PROCARGS2` that returns argc + argv + envp for any
    /// process the caller has permission to read (same-user
    /// processes work without extra entitlements; root-owned
    /// processes need root).
    static func commandLine(of pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        // First call: discover required buffer size.
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) < 0 || size == 0 {
            return ""
        }
        var buf = [CChar](repeating: 0, count: size)
        if sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) < 0 {
            return ""
        }
        // Layout: first 4 bytes = argc (int32), then exec path
        // (NUL-terminated), then argv[0]..argv[argc-1] (each
        // NUL-terminated), then envp.
        return buf.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress, size >= 4 else { return "" }
            let argc = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            var cursor = 4
            // Skip exec path.
            while cursor < size && buf[cursor] != 0 { cursor += 1 }
            // Skip any padding NULs.
            while cursor < size && buf[cursor] == 0 { cursor += 1 }
            var args: [String] = []
            for _ in 0..<argc {
                guard cursor < size else { break }
                let start = cursor
                while cursor < size && buf[cursor] != 0 { cursor += 1 }
                let slice = Array(buf[start..<cursor])
                if let s = String(validatingUTF8: slice + [0]) {
                    args.append(s)
                }
                cursor += 1
            }
            return args.joined(separator: " ")
        }
    }
}

import Darwin

/// The process table, read with `sysctl`. Compiled into both the app and `notched-agent`, so the
/// helper's "which process is the agent" and the app's "is it still running" compare the same values.
enum AgentProcess {
    struct Info: Equatable {
        let pid: Int32
        let parent: Int32
        /// Seconds since 1970. With the pid, it names one process: a reused pid has another start.
        let start: Double
        let name: String
    }

    static func info(_ pid: Int32) -> Info? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = kinfo.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Info(pid: pid, parent: kinfo.kp_eproc.e_ppid,
                    start: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000, name: name)
    }

    /// The agent behind a hook: the first ancestor of `pid` that is not a shell. Claude Code runs a
    /// hook command through `sh -c`, so the hook's parent is a shell and its grandparent the agent.
    static func agent(above pid: Int32) -> Info? {
        let shells: Set = ["sh", "bash", "zsh", "dash", "fish"]
        var current = info(pid)
        for _ in 0..<8 {
            guard let process = current else { return nil }
            if !shells.contains(process.name) { return process }
            current = info(process.parent)
        }
        return nil
    }

    static func isRunning(pid: Int32, start: Double) -> Bool {
        info(pid)?.start == start
    }
}

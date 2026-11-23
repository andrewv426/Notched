import Foundation
import NotchedCore
import os

/// Turns the agent inbox (one JSON file per session, written by `notched-agent`) into one
/// `.agents` snapshot event: at start, whenever the directory changes, and whenever an agent
/// process it saw running exits. It decides nothing: liveness is read from the process table, and
/// `AgentRecord.isGarbage` says which files may go.
@MainActor
final class AgentInbox {
    let directory: URL
    private let send: @MainActor ([AgentSession]) -> Void
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var exitWatches: [Int32: DispatchSourceProcess] = [:]
    private var pending = false
    private static let log = Logger(subsystem: "app.notched.Notched", category: "agents")

    init(directory: URL, send: @escaping @MainActor ([AgentSession]) -> Void) {
        self.directory = directory
        self.send = send
    }

    func start() {
        guard directoryWatch == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            // A rename into the directory is a write to it.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleScan() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            directoryWatch = source
        } else {
            Self.log.error("cannot watch \(self.directory.path, privacy: .public)")
        }
        scan()
    }

    /// Coalesces a burst of hook writes (parallel tool calls) into one read.
    private func scheduleScan() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.pending = false
            self?.scan()
        }
    }

    /// Reads every record and sends the whole snapshot. Safe to call any number of times.
    func scan() {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let wallNow = Date().timeIntervalSince1970
        let now = Instant.now
        var sessions: [AgentSession] = []
        var running: Set<Int32> = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? .max) <= 64 * 1024,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(AgentRecord.self, from: data),
                  record.v == AgentRecord.version else {
                Self.log.info("skipped \(name, privacy: .public): not a readable record")
                continue
            }
            let liveness = Self.liveness(of: record)
            if record.isGarbage(liveness: liveness, wallNow: wallNow) {
                try? manager.removeItem(at: file)
                continue
            }
            if liveness == .alive, let pid = record.pid { running.insert(pid) }
            sessions.append(AgentSession(record: record, liveness: liveness, wallNow: wallNow, now: now))
        }
        watchExits(of: running)
        send(sessions)
    }

    private static func liveness(of record: AgentRecord) -> Liveness {
        guard let pid = record.pid, let start = record.pidStart else { return .untracked }
        return AgentProcess.isRunning(pid: pid, start: start) ? .alive : .exited
    }

    /// One exit watch per running agent process, so a killed agent leaves the notch at once.
    private func watchExits(of pids: Set<Int32>) {
        for (pid, source) in exitWatches where !pids.contains(pid) {
            source.cancel()
            exitWatches[pid] = nil
        }
        for pid in pids where exitWatches[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleScan() } }
            source.resume()
            exitWatches[pid] = source
        }
    }
}

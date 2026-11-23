import Foundation

public struct AgentSessionID: Hashable, Sendable {
    public let tool: AgentTool
    public let session: String

    public init(tool: AgentTool, session: String) {
        self.tool = tool
        self.session = session
    }
}

/// One session as the domain sees it: a record read from the inbox, with its times on the app's clock.
public struct AgentSession: Equatable, Sendable, Identifiable {
    public let id: AgentSessionID
    /// The last path component of the agent's working directory.
    public let project: String
    public let status: AgentStatus
    public let toolName: String?
    public let host: String?
    public let since: Instant
    /// The record's wall-clock `since`. It identifies the current status exactly, where `since` is
    /// re-derived on every read and moves by microseconds.
    let stamp: Double
    let lastHeard: Instant
    let liveness: Liveness

    /// Converts wall-clock seconds to instants on this process's clock, so the domain keeps one clock.
    /// A time in the future (a clock change) is clamped to `now`.
    public init(record: AgentRecord, liveness: Liveness, wallNow: Double, now: Instant) {
        func instant(_ wall: Double) -> Instant { now.advanced(by: .seconds(-max(0, wallNow - wall))) }
        id = AgentSessionID(tool: record.tool, session: record.session)
        project = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? record.session
        status = record.status
        toolName = record.toolName
        host = record.host
        since = instant(record.since)
        stamp = record.since
        lastHeard = instant(record.updated)
        self.liveness = record.effective(liveness)
    }
}

/// A row in the open panel was clicked: bring the app the agent runs in to the front, once per `at`.
public struct AgentFocusRequest: Equatable, Sendable {
    public let session: AgentSessionID
    public let host: String?
    public let at: Instant
}

/// The agents part of `NotchState`. The inbox's latest snapshot, plus what the user has seen of it.
///
/// A done or needs-input status needs attention until the user has seen it: the Agents page was on
/// screen while it was showing. A seen done or failed turn leaves once the notch closes. A seen
/// needs-input status stays in the list, because it is still true, but stops taking the wings.
public struct AgentBoard: Equatable, Sendable {
    /// An unseen finished turn disappears this long after it finished.
    public static let expiry: Duration = .seconds(60 * 60)
    /// A session without a pid that has not reported for this long is gone.
    public static let silence: Duration = .seconds(6 * 60 * 60)

    /// The inbox as last read. A session missing from it is gone.
    public private(set) var sessions: [AgentSession] = []
    /// What the user has done about each session's current status, keyed by session. A mark counts
    /// only while its stamp is the session's: a new status needs attention again.
    var marks: [AgentSessionID: Mark] = [:]
    public private(set) var focusRequest: AgentFocusRequest?
    /// Turns that finished before Notched launched count as seen and closed: the agent's own app has
    /// told the user, and a relaunch must not pulse old news.
    let launchedAt: Instant

    struct Mark: Equatable, Sendable {
        let stamp: Double
        var notice: Notice
    }

    enum Notice: Equatable, Sendable {
        case seen
        /// Hidden until the status changes.
        case cleared
    }

    init(launchedAt: Instant) {
        self.launchedAt = launchedAt
    }

    // MARK: Changes, called only by `NotchState.reduce`

    mutating func replace(with snapshot: [AgentSession]) {
        sessions = snapshot
        let current = Dictionary(snapshot.map { ($0.id, $0.stamp) }, uniquingKeysWith: { a, _ in a })
        marks = marks.filter { current[$0.key] == $0.value.stamp }
        for s in snapshot where s.status.isFinished && s.since < launchedAt && marks[s.id] == nil {
            marks[s.id] = Mark(stamp: s.stamp, notice: .cleared)
        }
    }

    /// Clears finished turns past `expiry` and untracked sessions past `silence`. Idempotent.
    mutating func settle(at now: Instant) {
        for s in sessions where notice(s) != .cleared {
            if let end = expiry(of: s), now >= end { marks[s.id] = Mark(stamp: s.stamp, notice: .cleared) }
        }
    }

    /// Everything on the Agents page that needs attention is now seen.
    mutating func see() {
        for s in visible where notice(s) == nil && (s.status.needsInput || s.status.isFinished) {
            marks[s.id] = Mark(stamp: s.stamp, notice: .seen)
        }
    }

    /// The notch closed: seen finished turns leave.
    mutating func clearSeen() {
        for s in sessions where s.status.isFinished && notice(s) == .seen {
            marks[s.id] = Mark(stamp: s.stamp, notice: .cleared)
        }
    }

    mutating func activate(_ id: AgentSessionID, at now: Instant) {
        guard let s = visible.first(where: { $0.id == id }) else { return }
        if notice(s) == nil, s.status != .working { marks[s.id] = Mark(stamp: s.stamp, notice: .seen) }
        focusRequest = AgentFocusRequest(session: id, host: s.host, at: now)
    }

    // MARK: Projections

    /// Every session to list, most urgent first: unseen needs-input, failed, done; then seen
    /// needs-input; then seen finished turns (only while the notch is still open); then working.
    /// Newest first within each group.
    public var visible: [AgentSession] {
        sessions
            .filter { notice($0) != .cleared && !($0.liveness == .exited && !$0.status.isFinished) }
            .sorted { (rank($0), $1.since) < (rank($1), $0.since) }
    }

    /// Unseen sessions that need the user, most urgent first.
    public var attention: [AgentSession] {
        visible.filter { notice($0) == nil && $0.status != .working }
    }

    /// The colour of the badge: the most urgent visible status.
    public var tone: AgentStatus? { visible.first?.status }

    /// Whether the user has seen this session's current status.
    public func isSeen(_ s: AgentSession) -> Bool { notice(s) != nil }

    /// The earliest instant a session expires on its own.
    var deadline: Instant? {
        sessions.filter { notice($0) != .cleared }.compactMap(expiry(of:)).min()
    }

    private func notice(_ s: AgentSession) -> Notice? {
        marks[s.id].flatMap { $0.stamp == s.stamp ? $0.notice : nil }
    }

    private func expiry(of s: AgentSession) -> Instant? {
        if s.status.isFinished { return s.since.advanced(by: Self.expiry) }
        if s.liveness == .untracked { return s.lastHeard.advanced(by: Self.silence) }
        return nil
    }

    private func rank(_ s: AgentSession) -> Int {
        let unseen = notice(s) == nil
        switch s.status {
        case .permission, .question: return unseen ? 0 : 3
        case .failed: return unseen ? 1 : 4
        case .done: return unseen ? 2 : 4
        case .working: return 5
        }
    }
}

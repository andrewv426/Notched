import Foundation

/// The coding agent a session belongs to. Hooks name it on the command line (`notched-agent hook claude`).
public enum AgentTool: String, Codable, Hashable, Sendable {
    case claude
}

/// What a session is doing, as its hooks last reported it.
public enum AgentStatus: String, Codable, Hashable, Sendable {
    case working
    /// Waiting for the user to allow a tool.
    case permission
    /// Asked the user something, or has a plan for them to review.
    case question
    /// The turn ended.
    case done
    /// The turn ended on an error (an API failure, for example).
    case failed

    public var needsInput: Bool { self == .permission || self == .question }
    public var isFinished: Bool { self == .done || self == .failed }
}

/// One session's file in the inbox, written by `notched-agent` and read by the app. It crosses
/// processes, so its times are wall-clock seconds since 1970; `AgentSession` converts them at the
/// boundary.
public struct AgentRecord: Codable, Equatable, Sendable {
    public static let version = 1

    public var v: Int
    public var tool: AgentTool
    public var session: String
    public var cwd: String?
    public var status: AgentStatus
    /// The tool the agent last started, finished or asked about, such as `Bash`.
    public var toolName: String?
    /// When `status` began. Reporting the same status again keeps it, so it identifies the status.
    public var since: Double
    /// When any hook last wrote this file.
    public var updated: Double
    /// The agent process said it is exiting (`SessionEnd`).
    public var ended: Bool
    /// The agent process and its start time, so a reused pid does not count as the same process.
    public var pid: Int32?
    public var pidStart: Double?
    /// The bundle id of the app the agent runs in (`__CFBundleIdentifier`): Terminal, T3 Code, …
    public var host: String?

    public init(tool: AgentTool, session: String, cwd: String?, status: AgentStatus, toolName: String?,
                since: Double, updated: Double, ended: Bool, pid: Int32?, pidStart: Double?, host: String?) {
        v = Self.version
        self.tool = tool
        self.session = session
        self.cwd = cwd
        self.status = status
        self.toolName = toolName
        self.since = since
        self.updated = updated
        self.ended = ended
        self.pid = pid
        self.pidStart = pidStart
        self.host = host
    }

    /// `<tool>-<session>.json`. Nil for a session id that is not a safe file name, so a hook can never
    /// write outside the inbox.
    public static func fileName(tool: AgentTool, session: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...128).contains(session.count), session.allSatisfy(allowed.contains) else { return nil }
        return "\(tool.rawValue)-\(session).json"
    }

    /// Whether the app may delete this file: nothing it says can be shown again until a hook writes a
    /// new status. A finished turn past `AgentBoard.expiry`, an active one whose process has gone, or
    /// an untracked one silent for `AgentBoard.silence`.
    public func isGarbage(liveness: Liveness, wallNow: Double) -> Bool {
        if status.isFinished { return wallNow - since >= AgentBoard.expiry.seconds }
        switch effective(liveness) {
        case .alive: return false
        case .exited: return true
        case .untracked: return wallNow - updated >= AgentBoard.silence.seconds
        }
    }

    /// `ended` overrides what the process table says: the agent announced its exit.
    func effective(_ observed: Liveness) -> Liveness { ended ? .exited : observed }
}

/// Whether the process that wrote a record is still running, as the app observed it.
public enum Liveness: Equatable, Sendable {
    case alive
    case exited
    /// The record has no pid, so only silence can retire it.
    case untracked
}

/// Where hooks write and the app reads: `$NOTCHED_AGENT_INBOX`, otherwise
/// `~/Library/Application Support/Notched/agents`. Tests and the self-test always set the variable.
public enum AgentInboxPath {
    public static let environmentKey = "NOTCHED_AGENT_INBOX"

    public static func directory(environment: [String: String], home: URL) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Notched/agents", isDirectory: true)
    }
}

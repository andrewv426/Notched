/// The fields `notched-agent` reads from a Claude Code hook's stdin. Every other field is ignored.
public struct HookInput: Decodable, Equatable, Sendable {
    public let sessionID: String
    public let event: String
    public let cwd: String?
    public let toolName: String?
    public let notificationType: String?
    /// Set when a subagent sent the event.
    public let agentID: String?

    public init(sessionID: String, event: String, cwd: String? = nil, toolName: String? = nil,
                notificationType: String? = nil, agentID: String? = nil) {
        self.sessionID = sessionID
        self.event = event
        self.cwd = cwd
        self.toolName = toolName
        self.notificationType = notificationType
        self.agentID = agentID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case event = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case agentID = "agent_id"
    }
}

/// What the helper finds out about the process that ran the hook.
public struct HookContext: Equatable, Sendable {
    public let tool: AgentTool
    public let pid: Int32?
    public let pidStart: Double?
    public let host: String?

    public init(tool: AgentTool, pid: Int32?, pidStart: Double?, host: String?) {
        self.tool = tool
        self.pid = pid
        self.pidStart = pidStart
        self.host = host
    }
}

/// Turns one hook event into the session's next record. Pure, so every row of the table is a unit test.
public enum HookMapping {
    /// What an event does to a session.
    enum Change: Equatable {
        case status(AgentStatus)
        /// The agent process is exiting. The status stays: a finished turn must outlive the process,
        /// because T3 Code stops `claude` after every turn.
        case end
    }

    ///   event                                   | change
    ///   UserPromptSubmit                        | working
    ///   PreToolUse AskUserQuestion/ExitPlanMode | question
    ///   PreToolUse (any other tool)             | working ¹
    ///   PermissionRequest                       | permission
    ///   Notification permission_prompt          | permission
    ///   Notification elicitation_*, agent_needs_input | question
    ///   PostToolUse, PostToolUseFailure, PermissionDenied | working ¹
    ///   Stop                                    | done
    ///   StopFailure                             | failed
    ///   SessionEnd                              | end
    ///   anything else (idle_prompt, …)          | nothing
    ///
    /// ¹ Not when a subagent sends it after the turn finished: a background subagent must not reopen it.
    static func change(for input: HookInput, previous: AgentRecord?) -> Change? {
        let toolActivity: Change? = input.agentID != nil && previous?.status.isFinished == true ? nil : .status(.working)
        switch input.event {
        case "UserPromptSubmit": return .status(.working)
        case "PreToolUse":
            return ["AskUserQuestion", "ExitPlanMode"].contains(input.toolName) ? .status(.question) : toolActivity
        case "PermissionRequest": return .status(.permission)
        case "Notification":
            switch input.notificationType {
            case "permission_prompt": return .status(.permission)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .status(.question)
            default: return nil
            }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied": return toolActivity
        case "Stop": return .status(.done)
        case "StopFailure": return .status(.failed)
        case "SessionEnd": return .end
        default: return nil
        }
    }

    /// The record to write, or nil to write nothing. `since` is kept while the status repeats, so a
    /// stream of tool calls does not reset how long the agent has been working, or what was seen.
    public static func next(_ input: HookInput, previous: AgentRecord?, context: HookContext,
                            wallNow: Double) -> AgentRecord? {
        guard let change = change(for: input, previous: previous) else { return nil }
        switch change {
        case .end:
            guard var record = previous else { return nil }
            record.ended = true
            record.updated = wallNow
            return record
        case .status(let status):
            // A Notification names no tool; the permission it announces is for the tool just started.
            let toolName = input.toolName ?? (status == .permission ? previous?.toolName : nil)
            return AgentRecord(
                tool: context.tool, session: input.sessionID, cwd: input.cwd ?? previous?.cwd,
                status: status, toolName: toolName,
                since: previous?.status == status ? previous?.since ?? wallNow : wallNow,
                updated: wallNow, ended: false,
                pid: context.pid, pidStart: context.pidStart, host: context.host ?? previous?.host)
        }
    }
}

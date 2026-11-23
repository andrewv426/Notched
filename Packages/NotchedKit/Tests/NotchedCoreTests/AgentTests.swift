import CoreGraphics
import Foundation
import Testing
@testable import NotchedCore

private let t0 = ContinuousClock.now
private let wall0 = 1_800_000_000.0
private let geometry = NotchGeometry(
    screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    hardwareNotch: CGRect(x: 662, y: 950, width: 188, height: 32)
)
private let onNotch = CGPoint(x: 756, y: 970)
private let farAway = CGPoint(x: 100, y: 100)
private let context = HookContext(tool: .claude, pid: 4242, pidStart: 1_799_999_000.5, host: "com.apple.Terminal")

private func secs(_ s: Double) -> Instant { t0.advanced(by: .seconds(s)) }

/// A session whose status began `since` seconds after t0, observed at t0 + `seen`.
private func session(_ name: String, _ status: AgentStatus, since: Double = 1, at seen: Double = 1,
                     liveness: Liveness = .alive, cwd: String = "/Users/me/src/Notched") -> AgentSession {
    let record = AgentRecord(tool: .claude, session: name, cwd: cwd, status: status, toolName: "Bash",
                             since: wall0 + since, updated: wall0 + since, ended: false,
                             pid: 1, pidStart: 1, host: "com.t3tools.t3code")
    return AgentSession(record: record, liveness: liveness, wallNow: wall0 + seen, now: secs(seen))
}

private func id(_ name: String) -> AgentSessionID { AgentSessionID(tool: .claude, session: name) }

private func launched() -> NotchState { NotchState(geometry: geometry, now: t0) }

@Suite struct Hooks {
    private func run(_ events: [HookInput], wall: Double = wall0) -> AgentRecord? {
        var record: AgentRecord?
        for (i, e) in events.enumerated() {
            record = HookMapping.next(e, previous: record, context: context, wallNow: wall + Double(i)) ?? record
        }
        return record
    }

    private func event(_ name: String, tool: String? = nil, type: String? = nil, agent: String? = nil) -> HookInput {
        HookInput(sessionID: "s1", event: name, cwd: "/Users/me/src/Notched", toolName: tool,
                  notificationType: type, agentID: agent)
    }

    @Test(arguments: [
        ("UserPromptSubmit", nil, nil, AgentStatus.working),
        ("PreToolUse", "Bash", nil, .working),
        ("PreToolUse", "AskUserQuestion", nil, .question),
        ("PreToolUse", "ExitPlanMode", nil, .question),
        ("PermissionRequest", "Bash", nil, .permission),
        ("Notification", nil, "permission_prompt", .permission),
        ("Notification", nil, "elicitation_dialog", .question),
        ("Notification", nil, "agent_needs_input", .question),
        ("PostToolUse", "Bash", nil, .working),
        ("PostToolUseFailure", "Bash", nil, .working),
        ("PermissionDenied", "Bash", nil, .working),
        ("Stop", nil, nil, .done),
        ("StopFailure", nil, nil, .failed),
    ] as [(String, String?, String?, AgentStatus)])
    func eachEventMapsToItsStatus(name: String, tool: String?, type: String?, status: AgentStatus) {
        let record = HookMapping.next(event(name, tool: tool, type: type), previous: nil, context: context, wallNow: wall0)
        #expect(record?.status == status)
        #expect(record?.pid == 4242 && record?.host == "com.apple.Terminal" && record?.ended == false)
    }

    @Test func idleAndUnknownEventsWriteNothing() {
        #expect(HookMapping.next(event("Notification", type: "idle_prompt"), previous: nil, context: context, wallNow: wall0) == nil)
        #expect(HookMapping.next(event("SubagentStop"), previous: nil, context: context, wallNow: wall0) == nil)
        #expect(HookMapping.next(event("SessionEnd"), previous: nil, context: context, wallNow: wall0) == nil)
    }

    @Test func repeatingAStatusKeepsWhenItBegan() {
        let r = run([event("UserPromptSubmit"), event("PreToolUse", tool: "Read"), event("PostToolUse", tool: "Read"),
                     event("PreToolUse", tool: "Bash")])
        #expect(r?.since == wall0)
        #expect(r?.updated == wall0 + 3)
        #expect(r?.toolName == "Bash")
    }

    @Test func aNewStatusStartsANewSince() {
        let r = run([event("UserPromptSubmit"), event("Stop")])
        #expect(r?.status == .done && r?.since == wall0 + 1)
    }

    @Test func aPermissionNotificationNamesTheToolJustStarted() {
        let r = run([event("PreToolUse", tool: "Bash"), event("Notification", type: "permission_prompt")])
        #expect(r?.status == .permission && r?.toolName == "Bash")
    }

    @Test func sessionEndKeepsTheFinishedTurn() {
        let r = run([event("UserPromptSubmit"), event("Stop"), event("SessionEnd")])
        #expect(r?.status == .done && r?.ended == true && r?.since == wall0 + 1)
    }

    @Test func aBackgroundSubagentDoesNotReopenAFinishedTurn() {
        let r = run([event("UserPromptSubmit"), event("Stop"), event("PostToolUse", tool: "Bash", agent: "a1"),
                     event("PreToolUse", tool: "Read", agent: "a1")])
        #expect(r?.status == .done)
        let asking = run([event("Stop"), event("PermissionRequest", tool: "Bash", agent: "a1")])
        #expect(asking?.status == .permission)
    }

    @Test func aNewPromptAfterTheProcessEndedIsAliveAgain() {
        let r = run([event("Stop"), event("SessionEnd"), event("UserPromptSubmit")])
        #expect(r?.status == .working && r?.ended == false)
    }

    @Test func theHookPayloadDecodesFromClaudeCodeJSON() throws {
        let json = #"{"session_id":"abc-123","transcript_path":"/x","cwd":"/r","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        #expect(input == HookInput(sessionID: "abc-123", event: "PreToolUse", cwd: "/r", toolName: "Bash"))
    }

    @Test func onlySafeSessionIdsBecomeFileNames() {
        #expect(AgentRecord.fileName(tool: .claude, session: "6f1c-AB_9") == "claude-6f1c-AB_9.json")
        #expect(AgentRecord.fileName(tool: .claude, session: "../../etc") == nil)
        #expect(AgentRecord.fileName(tool: .claude, session: "") == nil)
    }

    @Test func theInboxIsOverriddenByTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(AgentInboxPath.directory(environment: [:], home: home).path == "/Users/me/Library/Application Support/Notched/agents")
        #expect(AgentInboxPath.directory(environment: ["NOTCHED_AGENT_INBOX": "/tmp/x"], home: home).path == "/tmp/x")
    }
}

@Suite struct Records {
    private func record(_ status: AgentStatus, since: Double, ended: Bool = false) -> AgentRecord {
        AgentRecord(tool: .claude, session: "s", cwd: nil, status: status, toolName: nil, since: wall0 + since,
                    updated: wall0 + since, ended: ended, pid: 1, pidStart: 1, host: nil)
    }

    @Test func wallClockBecomesInstantsAtTheBoundary() {
        let s = AgentSession(record: record(.working, since: 10), liveness: .alive, wallNow: wall0 + 70, now: secs(100))
        #expect(s.since == secs(40))
        let future = AgentSession(record: record(.working, since: 200), liveness: .alive, wallNow: wall0 + 70, now: secs(100))
        #expect(future.since == secs(100))
    }

    @Test func endedCountsAsExited() {
        let s = AgentSession(record: record(.working, since: 0, ended: true), liveness: .alive, wallNow: wall0, now: t0)
        #expect(s.liveness == .exited)
    }

    @Test func garbageIsWhatCanNeverShowAgain() {
        #expect(!record(.done, since: 0).isGarbage(liveness: .exited, wallNow: wall0 + 3599))
        #expect(record(.done, since: 0).isGarbage(liveness: .alive, wallNow: wall0 + 3600))
        #expect(record(.working, since: 0).isGarbage(liveness: .exited, wallNow: wall0))
        #expect(record(.permission, since: 0, ended: true).isGarbage(liveness: .alive, wallNow: wall0))
        #expect(!record(.working, since: 0).isGarbage(liveness: .alive, wallNow: wall0 + 100_000))
        #expect(!record(.working, since: 0).isGarbage(liveness: .untracked, wallNow: wall0 + 6 * 3600 - 1))
        #expect(record(.working, since: 0).isGarbage(liveness: .untracked, wallNow: wall0 + 6 * 3600))
    }
}

@Suite struct AgentsInTheNotch {
    @Test func busyAgentsGrowNarrowWingsAndASnapshotIsIdempotent() {
        var s = launched()
        s.reduce(.agents([session("a", .working), session("b", .working)]), at: secs(1))
        #expect(s.layout == .peek)
        #expect(s.wings == .agentsBusy(count: 2))
        let before = s
        s.reduce(.agents([session("a", .working), session("b", .working)]), at: secs(1))
        #expect(s == before)
        s.reduce(.agents([]), at: secs(2))
        #expect(s.layout == .dormant)
    }

    @Test func doneStaysUntilSeenAndLeavesWhenTheNotchCloses() {
        var s = launched()
        s.reduce(.agents([session("a", .working)]), at: secs(1))
        s.reduce(.agents([session("a", .done, since: 60, at: 60)]), at: secs(60))
        #expect(s.layout == .callout)
        guard case .agentAttention(let top, others: 0) = s.wings else { Issue.record("\(String(describing: s.wings))"); return }
        #expect(top.id == id("a") && top.project == "Notched")
        s.reduce(.tick, at: secs(600))
        #expect(s.layout == .callout)

        s.reduce(.pointerDown(onNotch), at: secs(700))
        #expect(s.page == .agents)
        #expect(s.agents.attention.isEmpty)
        #expect(s.agents.visible.map(\.id) == [id("a")])
        s.reduce(.pointerDown(farAway), at: secs(701))
        #expect(s.agents.visible.isEmpty)
        #expect(s.layout == .dormant)

        s.reduce(.agents([session("a", .done, since: 60, at: 800)]), at: secs(800))
        #expect(s.agents.visible.isEmpty)
        s.reduce(.agents([session("a", .working, since: 900, at: 900)]), at: secs(900))
        #expect(s.layout == .peek)
    }

    @Test func anUnseenDoneExpiresAfterAnHour() {
        var s = launched()
        s.reduce(.agents([session("a", .done, since: 10, at: 10)]), at: secs(10))
        #expect(s.nextDeadline == secs(3610))
        s.reduce(.tick, at: secs(3610))
        #expect(s.layout == .dormant)
        #expect(s.nextDeadline == nil)
    }

    @Test func seenNeedsInputStaysButGivesUpTheWings() {
        var s = launched()
        s.reduce(.agents([session("a", .permission)]), at: secs(1))
        #expect(s.layout == .callout)
        s.reduce(.pointerDown(onNotch), at: secs(2))
        s.reduce(.pointerDown(farAway), at: secs(3))
        #expect(s.wings == .agentsBusy(count: 1))
        #expect(s.agents.tone == .permission)
        s.reduce(.agents([session("a", .permission, since: 4, at: 4)]), at: secs(4))
        #expect(s.layout == .callout)
    }

    @Test func openingForTheTimerDoesNotSeeAgentsUntilTheirPageShows() {
        var s = launched()
        s.reduce(.run(TimerDuration(seconds: 60)!, .focus(.fifty)), at: t0)
        s.reduce(.tick, at: secs(60))
        s.reduce(.agents([session("a", .done, since: 61, at: 61)]), at: secs(61))
        #expect(s.wings == .timerDone)
        #expect(s.agentBadge == .done)
        s.reduce(.pointerDown(onNotch), at: secs(62))
        #expect(s.page == .timer)
        #expect(s.agents.attention.count == 1)
        s.reduce(.showPage(.agents), at: secs(63))
        #expect(s.agents.attention.isEmpty)
        s.reduce(.pointerDown(farAway), at: secs(64))
        #expect(s.layout == .dormant)
    }

    @Test func turnsFinishedBeforeLaunchDoNotPulse() {
        var s = NotchState(geometry: geometry, now: secs(100))
        s.reduce(.agents([session("old", .done, since: 50, at: 100), session("ask", .question, since: 50, at: 100)]), at: secs(100))
        #expect(s.agents.visible.map(\.id) == [id("ask")])
        #expect(s.layout == .callout)
    }

    @Test func activeSessionsWhoseProcessExitedDisappearButFinishedOnesStay() {
        var s = launched()
        s.reduce(.agents([session("w", .working, liveness: .exited), session("q", .question, liveness: .exited),
                          session("d", .done, liveness: .exited)]), at: secs(1))
        #expect(s.agents.visible.map(\.id) == [id("d")])
    }

    @Test func untrackedSessionsGoQuietAfterSilence() {
        var s = launched()
        s.reduce(.agents([session("u", .working, liveness: .untracked)]), at: secs(1))
        #expect(s.nextDeadline == secs(1).advanced(by: AgentBoard.silence))
        s.reduce(.tick, at: secs(1).advanced(by: AgentBoard.silence))
        #expect(s.layout == .dormant)
    }

    @Test func theListPutsTheMostUrgentFirst() {
        var s = launched()
        s.reduce(.agents([session("w", .working, since: 5), session("d", .done, since: 4), session("f", .failed, since: 3),
                          session("q", .question, since: 2), session("p", .permission, since: 6, at: 6)]), at: secs(6))
        #expect(s.agents.visible.map(\.id.session) == ["p", "q", "f", "d", "w"])
        #expect(s.wings == .agentAttention(s.agents.visible[0], others: 3))
    }

    @Test func clickingARowSeesItClosesTheNotchAndAsksForFocusOnce() {
        var s = launched()
        s.reduce(.agents([session("a", .done)]), at: secs(1))
        s.reduce(.pointerDown(onNotch), at: secs(2))
        s.reduce(.agentActivated(id("a")), at: secs(3))
        #expect(!s.surface.isOpen)
        #expect(s.agents.focusRequest == AgentFocusRequest(session: id("a"), host: "com.t3tools.t3code", at: secs(3)))
        #expect(s.agents.visible.isEmpty)
        let before = s
        s.reduce(.tick, at: secs(4))
        #expect(s.agents.focusRequest == before.agents.focusRequest)
    }

    @Test func showPageIsIgnoredWhileClosed() {
        var s = launched()
        s.reduce(.showPage(.agents), at: t0)
        #expect(s.page == .timer)
    }

    /// The closed notch's priority: unseen timer Done, then agent attention, then the timer, then busy agents.
    @Test(arguments: [
        (Timer.idle, Agents.none, nil as Expected?),
        (.idle, .working, .agentsBusy),
        (.idle, .attention, .agentAttention),
        (.running, .none, .timer),
        (.running, .working, .timer),
        (.running, .attention, .agentAttention),
        (.paused, .working, .timer),
        (.doneUnseen, .none, .timerDone),
        (.doneUnseen, .attention, .timerDone),
        (.doneSeen, .working, .agentsBusy),
        (.doneSeen, .attention, .agentAttention),
    ])
    func wingPriority(timer: Timer, agents: Agents, expected: Expected?) {
        var s = launched()
        let minute = TimerDuration(seconds: 60)!, hour = TimerDuration(seconds: 3600)!
        switch timer {
        case .idle: break
        case .running: s.reduce(.run(hour, .focus(.fifty)), at: t0)
        case .paused:
            s.reduce(.run(hour, .focus(.fifty)), at: t0)
            s.reduce(.timer(.pause), at: secs(1))
        case .doneUnseen:
            s.reduce(.run(minute, .focus(.fifty)), at: t0)
            s.reduce(.tick, at: secs(60))
        case .doneSeen:
            s.reduce(.run(minute, .focus(.fifty)), at: t0)
            s.reduce(.tick, at: secs(60))
            s.reduce(.pointerDown(onNotch), at: secs(61))
            s.reduce(.pointerDown(farAway), at: secs(62))
        }
        switch agents {
        case .none: break
        case .working: s.reduce(.agents([session("w", .working, since: 63, at: 63)]), at: secs(63))
        case .attention: s.reduce(.agents([session("q", .question, since: 63, at: 63)]), at: secs(63))
        }
        #expect(s.wings.map(Expected.init) == expected)
        let badge = s.agentBadge != nil
        #expect(badge == ([.timer, .timerDone].contains(expected) && agents != .none))
    }

    enum Timer: CaseIterable, Sendable { case idle, running, paused, doneUnseen, doneSeen }
    enum Agents: CaseIterable, Sendable { case none, working, attention }
    enum Expected: Sendable {
        case timerDone, agentAttention, timer, agentsBusy
        init(_ w: WingContent) {
            switch w {
            case .timerDone: self = .timerDone
            case .agentAttention: self = .agentAttention
            case .timer: self = .timer
            case .agentsBusy: self = .agentsBusy
            }
        }
    }
}

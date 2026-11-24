#if DEBUG
import AppKit
import NotchedCore

/// An in-process smoke test, run with `NOTCHED_SELFTEST=<output dir>` (see `Scripts/selftest.sh`).
///
/// It drives the real controller, panel and SwiftUI views with synthetic pointer events and key
/// presses, waits on the real deadline alarm, renders the panel to PNG files, and writes
/// `result.txt`: one line per check and a final `RESULT pass=N fail=N skip=N`. The process exits
/// non-zero on any failure.
@MainActor
enum SelfTest {
    static func run(controller: NotchController, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        var passed = 0, failed = 0, skipped = 0

        func check(_ condition: Bool, _ what: String) {
            log.append((condition ? "ok   " : "FAIL ") + what)
            if condition { passed += 1 } else { failed += 1 }
        }
        func skip(_ what: String, _ why: String) {
            log.append("skip \(what): \(why)")
            skipped += 1
        }
        /// Waits for a condition instead of guessing a delay, so the test is not timing-sensitive.
        func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func snapshot(_ name: String) -> Pixels? {
            guard let view = controller.panel?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                check(false, "\(name): the panel has no content view to render")
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage, let pixels = Pixels(image) else {
                check(false, "\(name): the snapshot has no bitmap")
                return nil
            }
            do { try pixels.png().write(to: output.appendingPathComponent("\(name).png")) } catch {
                check(false, "\(name): could not write the PNG: \(error.localizedDescription)")
            }
            return pixels
        }
        func key(_ characters: String, code: UInt16) {
            guard let panel = controller.panel,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { check(false, "build a key event for \(characters.debugDescription)"); return }
            panel.sendEvent(event)
        }

        guard let panel = controller.panel else {
            check(false, "the controller created its panel")
            finish(log: log, passed: passed, failed: failed + 1, skipped: skipped, output: output)
        }
        let g = controller.state.geometry
        // Where a real cursor rests when pushed up into the notch: the screen's top edge.
        let onNotch = CGPoint(x: g.notch.midX, y: g.screenFrame.maxY)
        let inPanel = CGPoint(x: g.notch.midX, y: g.activeRect(for: .expanded).minY + 20)
        let farAway = CGPoint(x: g.screenFrame.minX + 40, y: g.screenFrame.minY + 40)
        var state: NotchState { controller.state }

        log.append("note screen \(g.screenFrame), notch \(g.notch), hardware notch: \(g.hasHardwareNotch), background: \(TestHost.isBackground)")

        // MARK: Launch

        check(state.layout == .dormant, "launches closed and idle")
        check(panel.frame == g.canvas, "the panel's frame is the canvas \(g.canvas), got \(panel.frame)")
        check(panel.frame.maxY == g.screenFrame.maxY && panel.frame.midX == g.notch.midX,
              "the panel hangs from the top edge, centred on the notch")
        check(panel.isVisible && panel.level == .statusBar, "the panel is on screen above the menu bar")
        check(panel.styleMask.contains(.nonactivatingPanel) && !panel.isKeyWindow, "the panel is non-activating and not key")
        check(panel.ignoresMouseEvents, "closed with the pointer away, the panel lets clicks through")
        check(!NSApp.isActive, "launching does not make the app active")
        await pause(0.3)
        if let pixels = snapshot("01-dormant") {
            let black = pixels.share(of: (0, 0, 0))
            let expected = (g.notch.width * g.notch.height) / (g.canvas.width * g.canvas.height)
            check(abs(black - expected) < 0.03, "only the notch is drawn: black covers \(percent(black)) of the canvas (expected about \(percent(expected)))")
        }

        // MARK: Opening

        controller.send(.pointerMoved(onNotch, dragging: false))
        check(!panel.ignoresMouseEvents, "with the pointer on the notch, the panel takes the mouse")
        await pause(0.4)
        check(state.layout == .dormant, "resting the pointer on the notch does not open it")
        controller.send(.pointerDown(onNotch))
        check(state.layout == .expanded, "a click opens the notch at once")
        check(!panel.isKeyWindow, "opening does not make the panel key")
        await pause(0.8)
        if let pixels = snapshot("02-expanded-idle") {
            let black = pixels.share(of: (0, 0, 0))
            check(black > 0.55, "the open panel is drawn: black covers \(percent(black)) of the canvas")
        }

        controller.send(.pointerMoved(farAway, dragging: false))
        check(panel.ignoresMouseEvents, "with the pointer away, clicks go through at once")
        check(await waitFor { state.layout == .dormant }, "leaving closes the notch after the grace period (the deadline alarm fired)")

        controller.send(.pointerMoved(onNotch, dragging: true))
        check(panel.ignoresMouseEvents, "dragging across the closed notch does not take the mouse")
        controller.send(.pointerMoved(farAway, dragging: false))

        // MARK: Custom: type minutes, Return

        controller.send(.pointerDown(onNotch))
        let frontmost = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let frontBefore = frontmost()
        controller.send(.select(.custom))
        check(state.surface.mode == .editing, "choosing Custom starts typing")
        if controller.options.mayTakeKeyFocus {
            check(await waitFor(2) { panel.isKeyWindow }, "while typing, the panel is key")
            // A key non-activating panel reports NSApp.isActive, but the app in front stays in front:
            // its menu bar stays, and it gets the keyboard back when typing ends.
            check(frontmost() == frontBefore, "becoming key leaves the frontmost app in front")
        } else {
            skip("the panel becomes key while typing", "a background run never takes the keyboard; run Scripts/vm-selftest.sh")
        }
        key("1", code: 18)
        key("5", code: 23)
        check(state.entry.minutes == 15, "typed digits are minutes, got \(state.entry.minutes)")
        await pause(0.4)
        _ = snapshot("03-custom")
        key("\r", code: 36)
        guard case .running(let run) = state.countdown else {
            check(false, "Return starts the typed length, got \(state.countdown)")
            finish(log: log, passed: passed, failed: failed, skipped: skipped, output: output)
        }
        check(run.total.seconds == 15 * 60 && run.phase == .custom, "Return starts 15 minutes as Custom")
        check(state.surface.mode == .browsing, "Return stops typing")
        check(await waitFor(2) { !panel.isKeyWindow } && panel.isVisible, "after typing, the panel gives the keyboard back and stays on screen")
        if controller.options.mayTakeKeyFocus {
            check(await waitFor(2) { !NSApp.isActive } && frontmost() == frontBefore,
                  "after typing, the app is inactive again and the frontmost app is unchanged")
        }

        controller.send(.timer(.pause))
        let left = state.countdown.remaining(at: .now)
        await pause(0.3)
        check(state.countdown.remaining(at: .now) == left, "a paused timer holds its remainder")
        controller.send(.timer(.resume))
        check(state.countdown.deadline != nil, "resume runs again")
        await pause(0.6)
        _ = snapshot("04-running-open")

        controller.send(.pointerMoved(inPanel, dragging: false))
        controller.send(.pointerMoved(farAway, dragging: false))
        check(await waitFor { state.layout == .glance }, "closed while running, the notch shows the glance wings")
        await pause(0.8)
        if let pixels = snapshot("05-glance") {
            let black = pixels.share(of: (0, 0, 0))
            let size = g.size(for: .glance)
            let expected = (size.width * size.height) / (g.canvas.width * g.canvas.height)
            check(black > expected * 0.6 && black < expected * 1.1,
                  "the wings are drawn: black covers \(percent(black)) of the canvas (shape is \(percent(expected)))")
            check(pixels.share(of: (255, 255, 255), tolerance: 60) > 0.0005, "the wings show white text")
        }
        controller.send(.timer(.reset))
        check(state.layout == .dormant, "reset returns to idle and closed")

        // MARK: Completion and the next phase

        guard let two = TimerDuration(seconds: 2) else { return }
        controller.send(.pointerDown(onNotch))
        controller.send(.run(two, .focus(.fifty)))
        controller.send(.pointerDown(farAway))
        check(state.layout == .glance, "a run starts at once, and a click outside closes the notch")
        check(await waitFor(4) { state.layout == .alert }, "at the deadline the notch pulses Done (the alarm fired)")
        check(state.selection == .rest, "after a focus, the break is selected")
        await pause(0.8)
        _ = snapshot("06-alert")
        controller.send(.pointerDown(onNotch))
        check(state.layout == .expanded && state.ringing == nil, "clicking opens the finished timer and stops the pulse")
        check(state.startable == FocusLength.fifty.rest, "Start would run the 10-minute break")
        await pause(0.8)
        _ = snapshot("07-done-open")
        controller.send(.pointerDown(farAway))
        check(state.layout == .dormant, "once seen, a finished timer closes to the bare notch")

        controller.send(.pointerDown(onNotch))
        controller.send(.run(two, .rest))
        check(await waitFor(4) { state.ringing != nil }, "a timer that finishes while the notch is open still pulses")
        check(state.selection == .focus(.fifty), "after the break, the focus it followed is selected")
        controller.send(.timer(.reset))

        // MARK: Esc with the pointer resting on the notch

        controller.send(.select(.custom))
        key("\u{1b}", code: 53)
        check(state.layout == .dormant, "Esc closes the notch")
        check(state.selection == .custom, "Esc keeps Custom when it already has a length (15 minutes, from earlier)")
        await pause(0.5)
        check(state.layout == .dormant, "with the pointer still on the notch, it stays closed")
        controller.send(.pointerMoved(farAway, dragging: false))

        // MARK: Agents

        guard let inbox = controller.inbox, let me = AgentProcess.info(getpid()) else {
            check(false, "the controller watches an agent inbox")
            finish(log: log, passed: passed, failed: failed, skipped: skipped, output: output)
        }
        check(inbox.directory.path.hasPrefix(output.path), "the self-test reads its own agent inbox, not the user's")
        check(state.agents.visible.isEmpty, "the test inbox starts empty")
        func record(_ session: String, _ status: AgentStatus, project: String, tool: String? = "Bash",
                    process: AgentProcess.Info? = me) {
            let now = Date().timeIntervalSince1970
            let r = AgentRecord(tool: .claude, session: session, cwd: "/Users/test/src/\(project)", status: status,
                                toolName: tool, since: now, updated: now, ended: false, pid: process?.pid,
                                pidStart: process?.start, host: "com.apple.Terminal")
            guard let name = AgentRecord.fileName(tool: .claude, session: session),
                  let data = try? JSONEncoder().encode(r) else { return check(false, "encode \(session)") }
            do { try data.write(to: inbox.directory.appendingPathComponent(name), options: .atomic) } catch {
                check(false, "write \(session): \(error.localizedDescription)")
            }
        }
        func visible(_ session: String) -> AgentSession? { state.agents.visible.first { $0.id.session == session } }
        func colour(_ status: AgentStatus) -> (UInt8, UInt8, UInt8) {
            switch status {
            case .working: (128, 189, 255)
            case .permission, .question: (255, 166, 51)
            case .done: (82, 219, 128)
            case .failed: (255, 92, 92)
            }
        }

        record("busy-1", .working, project: "flotion")
        record("busy-2", .working, project: "arcx")
        check(await waitFor { state.layout == .peek && state.wings == .agentsBusy(count: 2) },
              "two working agents grow the narrow busy wings")
        await pause(0.8)
        if let pixels = snapshot("08-agents-busy") {
            let size = g.size(for: .peek)
            let expected = (size.width * size.height) / (g.canvas.width * g.canvas.height)
            let black = pixels.share(of: (0, 0, 0))
            check(black > expected * 0.6 && black < expected * 1.1,
                  "the busy wings are drawn: black covers \(percent(black)) of the canvas (shape is \(percent(expected)))")
            check(pixels.share(of: colour(.working), tolerance: 40) > 0.0002, "the busy wings show the working colour")
        }

        record("ask", .permission, project: "Notched")
        check(await waitFor { state.layout == .callout }, "an agent that needs permission takes the wings")
        if case .agentAttention(let top, let others) = state.wings {
            check(top.id.session == "ask" && others == 0, "the wings name the agent that asks, got \(top.project) +\(others)")
        } else {
            check(false, "the wings show agent attention, got \(String(describing: state.wings))")
        }
        await pause(0.8)
        if let pixels = snapshot("09-agent-attention") {
            check(pixels.share(of: colour(.permission), tolerance: 40) > 0.0002, "the callout shows the needs-input colour")
            check(pixels.share(of: (255, 255, 255), tolerance: 60) > 0.0005, "the callout shows the project name")
        }

        controller.send(.pointerDown(onNotch))
        check(state.layout == .expanded && state.page == .agents, "clicking the calling notch opens the Agents page")
        check(state.agents.attention.isEmpty, "opening the Agents page sees what it shows")
        check(state.agents.visible.map(\.id.session) == ["ask", "busy-1", "busy-2"] ||
              state.agents.visible.map(\.id.session) == ["ask", "busy-2", "busy-1"],
              "the list puts needs-input first, got \(state.agents.visible.map(\.id.session))")
        await pause(0.8)
        if let pixels = snapshot("10-agents-page") {
            check(pixels.share(of: (0, 0, 0)) > 0.45, "the Agents page is drawn")
            check(pixels.share(of: colour(.permission), tolerance: 40) > 0.0003, "the needs-input row is tinted")
        }
        controller.send(.showPage(.timer))
        check(state.page == .timer, "the Timer chip goes back to the timer")
        controller.send(.showPage(.agents))
        controller.send(.pointerDown(farAway))
        check(state.layout == .peek && state.agents.tone == .permission,
              "once seen, needs-input gives the wings back to the busy agents, tinted")

        record("busy-1", .done, project: "flotion", tool: nil)
        check(await waitFor { state.layout == .callout && state.agents.attention.first?.id.session == "busy-1" },
              "a finished turn takes the wings until it is seen")
        controller.send(.pointerDown(onNotch))
        controller.send(.agentActivated(AgentSessionID(tool: .claude, session: "busy-1")))
        check(!state.surface.isOpen, "clicking a row closes the notch")
        check(controller.focuser.lastRequest?.session.session == "busy-1"
              && controller.focuser.lastRequest?.host == "com.apple.Terminal",
              "clicking a row asks once for the agent's app (a test run activates nothing)")
        check(visible("busy-1") == nil, "the seen finished turn leaves when the notch closes")

        guard let minute = TimerDuration(seconds: 60) else { return }
        controller.send(.run(minute, .focus(.fifty)))
        check(state.layout == .glance && state.agentBadge == .permission,
              "with a timer running, agents become a dot on the timer's wings")
        await pause(0.8)
        if let pixels = snapshot("11-timer-with-agents") {
            check(pixels.share(of: colour(.permission), tolerance: 40) > 0.00005, "the badge dot is drawn")
        }
        record("busy-2", .question, project: "arcx", tool: "AskUserQuestion")
        check(await waitFor { state.layout == .callout }, "a new question outranks the running timer")
        controller.send(.timer(.reset))

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        if (try? sleeper.run()) != nil, let process = AgentProcess.info(sleeper.processIdentifier) {
            record("doomed", .working, project: "doomed", process: process)
            check(await waitFor { visible("doomed") != nil }, "an agent with a running process is listed")
            sleeper.terminate()
            check(await waitFor { visible("doomed") == nil }, "an agent whose process exits leaves at once")
            check(!FileManager.default.fileExists(atPath: inbox.directory.appendingPathComponent("claude-doomed.json").path),
                  "and its file is collected")
        } else {
            check(false, "start /bin/sleep as a stand-in agent")
        }

        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notched-agent")
        func hook(_ json: String) -> (status: Int32, stdout: Data, seconds: Double)? {
            let p = Process()
            p.executableURL = helper
            p.arguments = ["hook", "claude"]
            p.environment = [AgentInboxPath.environmentKey: inbox.directory.path]
            let input = Pipe(), out = Pipe()
            p.standardInput = input
            p.standardOutput = out
            let started = Date()
            guard (try? p.run()) != nil else { return nil }
            input.fileHandleForWriting.write(Data(json.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            return (p.terminationStatus, out.fileHandleForReading.readDataToEndOfFile(), Date().timeIntervalSince(started))
        }
        let prompt = hook(#"{"session_id":"helper-e2e","cwd":"/tmp/helper-project","hook_event_name":"UserPromptSubmit"}"#)
        check(prompt?.status == 0 && prompt?.stdout.isEmpty == true, "the built helper exits 0 and prints nothing")
        check(await waitFor { visible("helper-e2e")?.status == .working }, "the helper's prompt event lists the agent as working")
        _ = hook(#"{"session_id":"helper-e2e","hook_event_name":"Stop"}"#)
        check(await waitFor { visible("helper-e2e")?.status == .done && visible("helper-e2e")?.project == "helper-project" },
              "the helper's Stop event shows the turn as done")
        let junk = hook("not json")
        check(junk?.status == 0 && junk?.stdout.isEmpty == true, "a malformed payload still exits 0 silently")
        var timings: [Double] = []
        for _ in 0..<30 {
            if let run = hook(#"{"session_id":"helper-perf","hook_event_name":"PostToolUse","tool_name":"Read"}"#) {
                timings.append(run.seconds)
            }
        }
        let median = timings.sorted()[timings.count / 2] * 1000
        log.append(String(format: "PERF helper hook median %.1f ms over %d runs", median, timings.count))
        // About 5 ms on the host and 16 ms in the VM, spawn and pipes included. The guard catches a hook that
        // blocks (on Notched, a lock, the network), not a slow spawn.
        check(timings.count == 30 && median < 50, "a hook costs the agent under 50 ms (median \(Int(median)) ms)")

        for name in (try? FileManager.default.contentsOfDirectory(atPath: inbox.directory.path)) ?? [] {
            try? FileManager.default.removeItem(at: inbox.directory.appendingPathComponent(name))
        }
        check(await waitFor { state.agents.visible.isEmpty && state.layout == .dormant }, "an emptied inbox leaves the notch bare")

        // MARK: Music (synthetic now-playing events; no player is read or controlled)

        guard let media = controller.media else {
            check(false, "the controller has a media sink")
            finish(log: log, passed: passed, failed: failed, skipped: skipped, output: output)
        }
        check(state.media.nowPlaying == nil && state.media.volume == nil && media.count == 0,
              "a test run reads no real player or volume and has sent nothing")
        let artColour: (UInt8, UInt8, UInt8) = (230, 40, 160)
        let art = Pixels.squarePNG(colour: artColour).flatMap(controller.artwork.insert)
        check(art != nil, "artwork bytes go into the cache")
        let music = Player(bundleID: "com.apple.Music", name: "Music")
        func song(_ title: String, length: Double? = 215) -> NowPlaying {
            NowPlaying(player: music, track: Track(title: title, artist: "The Fixtures", album: "Self-Test",
                                                   duration: length.map { .seconds($0) }, artwork: art),
                       playback: .playing(elapsed: .seconds(30), instant: .now, rate: 1))
        }
        controller.send(.outputVolume(OutputVolume(level: 0.6, isMuted: false)))
        let first = song("Synthetic Song")
        controller.send(.nowPlaying(first))
        check(state.layout == .music, "playing music fills the closed notch's wings")
        await pause(0.8)
        if let pixels = snapshot("12-music-wings") {
            let size = g.size(for: .music)
            let expected = (size.width * size.height) / (g.canvas.width * g.canvas.height)
            let black = pixels.share(of: (0, 0, 0))
            check(black > expected * 0.6 && black < expected * 1.1,
                  "the music wings are drawn: black covers \(percent(black)) of the canvas (shape is \(percent(expected)))")
            check(pixels.share(of: artColour, tolerance: 30) > 0.0003, "the wings show the artwork")
        }

        controller.send(.pointerDown(onNotch))
        check(state.layout == .expanded && state.page == .music, "clicking the music wings opens the music page")
        await pause(0.8)
        if let pixels = snapshot("13-music-page") {
            check(pixels.share(of: (0, 0, 0)) > 0.45, "the music page is drawn")
            check(pixels.share(of: artColour, tolerance: 30) > 0.002, "the page shows the artwork")
            check(pixels.share(of: (255, 255, 255), tolerance: 40) > 0.003, "the page shows the title and the play button")
        }
        controller.send(.media(.togglePlayPause))
        check(media.lastCommand == .pause && media.count == 1 && state.media.nowPlaying?.isPlaying == false,
              "play/pause sends pause once and shows it paused at once")
        controller.send(.nowPlaying(first))
        check(state.media.nowPlaying?.isPlaying == false, "a stale playing report does not undo the click")
        controller.send(.media(.next))
        check(media.lastCommand == .next && media.count == 2, "next is sent once")
        controller.send(.media(.previous))
        check(media.lastCommand == .previous && media.count == 3, "previous is sent once")
        controller.send(.media(.seek(to: .seconds(90))))
        check(media.lastCommand == .seek(to: .seconds(90)), "a click on the scrubber seeks")
        controller.send(.media(.setVolume(0.25)))
        check(media.lastCommand == .setVolume(0.25) && state.media.volume?.level == 0.25, "the slider sets the Mac's volume")
        controller.send(.showPage(.timer))
        check(state.page == .timer && state.pages == [.timer, .music], "the timer page offers a music chip")
        await pause(0.6)
        _ = snapshot("14-timer-page-with-music")
        controller.send(.pointerDown(farAway))

        controller.send(.nowPlaying(song("Second Song")))
        controller.send(.run(minute, .focus(.fifty)))
        check(state.layout == .glance, "a running timer takes the wings from music")
        controller.send(.timer(.reset))
        check(state.layout == .music, "reset gives the wings back to music")

        controller.send(.nowPlaying(song("Live Radio", length: nil)))
        controller.send(.pointerDown(onNotch))
        let sent = media.count
        controller.send(.media(.seek(to: .seconds(10))))
        check(media.count == sent, "a live stream cannot seek")
        await pause(0.8)
        _ = snapshot("15-music-live")
        controller.send(.pointerDown(farAway))

        controller.send(.nowPlaying(nil))
        check(state.layout == .music, "a moment of nothing playing does not empty the notch")
        check(await waitFor(4) { state.layout == .dormant && state.media.nowPlaying == nil },
              "then music leaves the notch (the alarm fired)")

        // MARK: Screens

        let moved = NotchGeometry(screenFrame: g.screenFrame.offsetBy(dx: 0, dy: -200), hardwareNotch: nil)
        controller.send(.screensChanged(moved))
        check(panel.frame == moved.canvas, "a screen change moves the panel to the new canvas")
        controller.send(.screensChanged(g))
        check(panel.frame == g.canvas, "and back")

        if let problem = TestHost.savedWindowProblem() {
            check(false, problem)
        } else {
            check(true, "a test run does not restore or save the window")
        }
        if TestHost.focusTakenCount > 0 {
            log.append("note macOS made the background app active \(TestHost.focusTakenCount) time(s); it gave focus straight back")
        }
        finish(log: log, passed: passed, failed: failed, skipped: skipped, output: output)
    }

    /// The live media check, for the Tart VM only (`Scripts/vm-selftest.sh`): the real adapter reads a
    /// fixture player, every transport command must reach it, and the volume must reach CoreAudio.
    /// The fixture appends each command it receives to `NOTCHED_FIXTURE_LOG`.
    static func runLiveMedia(controller: NotchController, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ what: String) {
            log.append((condition ? "ok   " : "FAIL ") + what)
            if condition { passed += 1 } else { failed += 1 }
        }
        func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return condition()
        }
        var state: NotchState { controller.state }

        guard TestHost.isVirtualMac, controller.options.followsRealMedia, let media = controller.media,
              let logPath = ProcessInfo.processInfo.environment["NOTCHED_FIXTURE_LOG"] else {
            check(false, "the live media check runs only in a virtual Mac, with NOTCHED_FIXTURE_LOG set")
            finish(log: log, passed: passed, failed: failed, skipped: 0, output: output)
        }
        func received() -> [String] {
            ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func position() -> Double { state.media.nowPlaying.map { Double($0.position(at: .now).components.seconds) } ?? -1 }

        check(await waitFor(15) { state.media.nowPlaying?.player.bundleID == "app.notched.fixture-player" },
              "the adapter reports the fixture player")
        let first = state.media.nowPlaying
        check(first?.track.title == "Fixture Track 1" && first?.track.artist == "Notched Test"
              && first?.track.duration == .seconds(240) && first?.isPlaying == true,
              "with its title, artist and length, playing, got \(String(describing: first?.track))")
        check(first?.player.name == "FixturePlayer", "the player is named after its app, got \(first?.player.name ?? "nil")")
        check(state.layout == .music, "the closed notch shows the music wings")

        controller.send(.media(.togglePlayPause))
        check(await waitFor(5) { received().last == "pause" }, "play/pause reaches the player as pause")
        try? await Task.sleep(for: .seconds(2.5))
        check(state.media.nowPlaying?.isPlaying == false, "the player's own report keeps it paused after the timeout")
        controller.send(.media(.togglePlayPause))
        check(await waitFor(5) { received().last == "play" }, "and again as play")
        controller.send(.media(.next))
        check(await waitFor(5) { received().last == "next" && state.media.nowPlaying?.track.title == "Fixture Track 2" },
              "next reaches the player and the new track shows")
        controller.send(.media(.previous))
        check(await waitFor(5) { received().last == "previous" && state.media.nowPlaying?.track.title == "Fixture Track 1" },
              "previous reaches the player")
        controller.send(.media(.seek(to: .seconds(90))))
        check(await waitFor(5) { received().last == "seek 90.0" }, "a seek reaches the player at 90 s")
        try? await Task.sleep(for: .seconds(2.5))
        check((90...95).contains(position()), "the player's own report puts it at 90 s, got \(position()) s")
        controller.send(.media(.stop))
        check(await waitFor(5) { received().last == "stop" }, "stop reaches the player")
        check(media.count == 6, "six commands, each sent once, got \(media.count)")

        final class Box { var volume: OutputVolume? }
        let device = Box()
        let probe = SystemVolume { device.volume = $0 }
        probe.start()
        if let start = state.media.volume {
            let target = start.level > 0.5 ? 0.25 : 0.75
            controller.send(.media(.setVolume(target)))
            check(await waitFor(3) { device.volume.map { abs($0.level - target) < 0.02 && !$0.isMuted } == true },
                  "the slider sets the device's volume to \(target), CoreAudio reads \(String(describing: device.volume))")
            controller.send(.media(.setVolume(start.level)))
        } else {
            check(false, "CoreAudio reports a settable output volume in the VM")
        }
        finish(log: log, passed: passed, failed: failed, skipped: 0, output: output)
    }

    private static func finish(log: [String], passed: Int, failed: Int, skipped: Int, output: URL) -> Never {
        let lines = log + ["RESULT pass=\(passed) fail=\(failed) skip=\(skipped)"]
        try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("result.txt"),
                                                          atomically: true, encoding: .utf8)
        exit(failed == 0 ? 0 : 1)
    }

    private static func percent(_ share: Double) -> String { String(format: "%.1f%%", share * 100) }
}

/// A snapshot redrawn into a plain 8-bit sRGB bitmap, so colours compare with known values.
private struct Pixels {
    /// A 64-pixel square of one colour, as PNG bytes: stand-in artwork.
    static func squarePNG(colour: (UInt8, UInt8, UInt8)) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(colour.0) / 255, green: CGFloat(colour.1) / 255,
                                     blue: CGFloat(colour.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let image: CGImage

    init?(_ source: CGImage) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = source.width, height = source.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let drawn, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        bytes = buffer
        image = drawn
    }

    func png() throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// The share of opaque pixels within `tolerance` of `colour`. Transparent pixels never match.
    func share(of colour: (UInt8, UInt8, UInt8), tolerance: Int = 10) -> Double {
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 245 {
            if abs(Int(bytes[index]) - Int(colour.0)) <= tolerance,
               abs(Int(bytes[index + 1]) - Int(colour.1)) <= tolerance,
               abs(Int(bytes[index + 2]) - Int(colour.2)) <= tolerance {
                count += 1
            }
        }
        return Double(count) / Double(width * height)
    }
}
#endif

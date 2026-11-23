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

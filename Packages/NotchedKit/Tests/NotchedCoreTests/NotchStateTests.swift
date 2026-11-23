import CoreGraphics
import Testing
@testable import NotchedCore

// Behaviour as data: (state, event, now) → state, with no window, no clock and no sleeping.

private let t0 = ContinuousClock.now
private let geometry = NotchGeometry(
    screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    hardwareNotch: CGRect(x: 662, y: 950, width: 188, height: 32)
)
private let onNotch = CGPoint(x: 756, y: 970)
private let inPanel = CGPoint(x: 756, y: 860)
private let farAway = CGPoint(x: 100, y: 100)

private func at(_ ms: Int) -> Instant { t0.advanced(by: .milliseconds(ms)) }
private func seconds(_ s: Int) -> TimerDuration { TimerDuration(seconds: s)! }

private func openState() -> NotchState {
    var s = NotchState(geometry: geometry, now: t0)
    s.reduce(.pointerDown(onNotch), at: t0)
    return s
}

@Suite struct Countdowns {
    @Test func presetStartsAndFinishesAtItsDeadline() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(60)), at: t0)
        #expect(s.nextDeadline == t0.advanced(by: .seconds(60)))
        #expect(s.countdown.readout(at: at(500)).text == "1:00")
        s.reduce(.tick, at: at(61_000))
        #expect(s.ringing?.deadline == t0.advanced(by: .seconds(60)))
        #expect(s.layout == .alert)
    }

    @Test func pauseAfterTheDeadlineDoesNotBringTheTimerBack() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(60)), at: t0)
        s.reduce(.timer(.pause), at: at(61_000))   // the alarm has not fired yet
        guard case .finished = s.countdown else { Issue.record("expected finished, got \(s.countdown)"); return }
    }

    @Test func pauseKeepsTheExactRemainderAndResumeMovesTheDeadline() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(60)), at: t0)
        s.reduce(.timer(.pause), at: at(10_250))
        #expect(s.countdown.remaining(at: at(99_000)) == .milliseconds(49_750))
        #expect(s.nextDeadline == nil)
        s.reduce(.timer(.resume), at: at(20_000))
        #expect(s.nextDeadline == at(69_750))
    }

    @Test func replayingAnEventConverges() {
        var once = NotchState(geometry: geometry, now: t0)
        once.reduce(.preset(seconds(300)), at: t0)
        once.reduce(.timer(.pause), at: at(10_000))
        var twice = once
        twice.reduce(.timer(.pause), at: at(20_000))
        twice.reduce(.tick, at: at(30_000))
        #expect(once == twice)
    }

    @Test func openingTheNotchSilencesTheAlertForGood() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(1)), at: t0)
        s.reduce(.tick, at: at(1_000))
        #expect(s.ringing != nil)
        s.reduce(.pointerDown(onNotch), at: at(2_000))
        #expect(s.ringing == nil)
        s.reduce(.pointerDown(farAway), at: at(3_000))
        #expect(s.ringing == nil)
        #expect(s.layout == .alert)   // still shows Done until dismissed
        s.reduce(.timer(.reset), at: at(4_000))
        #expect(s.layout == .dormant)
    }

    @Test func aTimerThatFinishesWhileTheNotchIsOpenStillRings() {
        var s = openState()
        s.reduce(.preset(seconds(2)), at: t0)
        s.reduce(.tick, at: at(2_000))
        #expect(s.layout == .expanded)
        #expect(s.ringing != nil)
        s.reduce(.timer(.reset), at: at(3_000))   // Dismiss
        #expect(s.ringing == nil)
    }

    @Test func restartRunsTheSameDurationAgain() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(5)), at: t0)
        s.reduce(.tick, at: at(5_000))
        s.reduce(.timer(.start), at: at(6_000))
        #expect(s.nextDeadline == at(11_000))
    }

    @Test func readoutRoundsUpAndFormats() {
        #expect(Readout(wholeSeconds: 245).text == "4:05")
        #expect(Readout(wholeSeconds: 1500).text == "25:00")
        #expect(Readout(wholeSeconds: 3723).text == "1:02:03")
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.preset(seconds(60)), at: t0)
        #expect(s.countdown.readout(at: at(59_900)).text == "0:01")
    }
}

@Suite struct Hover {
    @Test func opensAfterTheDwellAndClosesAfterTheGrace() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(onNotch, dragging: false), at: t0)
        #expect(s.layout == .dormant)
        #expect(s.capturesPointer)
        #expect(s.nextDeadline == at(120))
        s.reduce(.tick, at: at(150))
        #expect(s.layout == .expanded)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(1_000))
        #expect(s.layout == .expanded)
        #expect(!s.capturesPointer)
        s.reduce(.tick, at: at(1_450))
        #expect(s.layout == .dormant)
    }

    @Test func aPointerPushedAgainstTheTopEdgeIsOnTheNotch() {
        // Where the cursor stops when you push it up into the notch: y is exactly the screen's maxY.
        let topEdge = CGPoint(x: 756, y: geometry.screenFrame.maxY)
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(topEdge, dragging: false), at: t0)
        #expect(s.capturesPointer)
        s.reduce(.tick, at: at(150))
        #expect(s.layout == .expanded)
        var c = NotchState(geometry: geometry, now: t0)
        c.reduce(.pointerDown(topEdge), at: t0)
        #expect(c.layout == .expanded)
    }

    @Test func aQuickSweepDoesNotOpen() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(onNotch, dragging: false), at: t0)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(60))
        s.reduce(.tick, at: at(500))
        #expect(s.layout == .dormant)
    }

    @Test func draggingAcrossTheClosedNotchDoesNotOpenOrTakeTheMouse() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(onNotch, dragging: true), at: t0)
        #expect(!s.capturesPointer)
        s.reduce(.tick, at: at(1_000))
        #expect(s.layout == .dormant)
    }

    @Test func movingWithinTheSameSideLeavesStateEqual() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(farAway, dragging: false), at: t0)
        var next = s
        next.reduce(.pointerMoved(CGPoint(x: 120, y: 140), dragging: false), at: at(8))
        #expect(next == s)
    }

    @Test func clickOpensAtOnceAndClickOutsideCloses() {
        var s = openState()
        #expect(s.layout == .expanded)
        s.reduce(.pointerDown(farAway), at: at(100))
        #expect(s.layout == .dormant)
    }

    @Test func escapeWithThePointerOnTheNotchStaysClosed() {
        var s = openState()
        s.reduce(.beginEditing, at: t0)
        s.reduce(.key(.cancel), at: at(1_000))
        s.reduce(.tick, at: at(5_000))
        #expect(!s.surface.isOpen)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(6_000))
        s.reduce(.pointerMoved(onNotch, dragging: false), at: at(7_000))
        s.reduce(.tick, at: at(7_200))
        #expect(s.surface.isOpen)   // left and came back
    }
}

@Suite struct Editing {
    @Test func typingFillsFromTheRightAndReturnStarts() {
        var s = openState()
        s.reduce(.beginEditing, at: t0)
        #expect(s.wantsKeyFocus)
        for d: Digit in [.zero, .one, .three, .zero, .zero] { s.reduce(.key(.digit(d)), at: t0) }
        #expect(s.entry.fields == (0, 13, 0))
        s.reduce(.key(.submit), at: at(10))
        #expect(!s.wantsKeyFocus)
        #expect(s.nextDeadline == at(10).advanced(by: .seconds(780)))
    }

    @Test func pointerExitIsIgnoredWhileEditing() {
        var s = openState()
        s.reduce(.beginEditing, at: t0)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(100))
        s.reduce(.tick, at: at(5_000))
        #expect(s.surface.mode == .editing)
        s.reduce(.keyFocusLost, at: at(6_000))
        #expect(!s.surface.isOpen)   // outside for longer than the grace: closes at once
    }

    @Test func editingIsRefusedWhileRunning() {
        var s = openState()
        s.reduce(.preset(seconds(60)), at: t0)
        s.reduce(.beginEditing, at: at(10))
        #expect(s.surface.mode == .browsing)
        s.reduce(.key(.digit(.five)), at: at(20))
        #expect(s.entry == DurationEntry(seconds(60)))
    }

    @Test func entryNormalisesAndCaps() {
        #expect(DurationEntry(seconds(90)).fields == (0, 1, 30))
        var e = DurationEntry()
        e.push(.zero)
        #expect(e.digits.isEmpty)
        for d: Digit in [.nine, .nine, .nine, .nine, .nine, .nine, .nine] { e.push(d) }
        #expect(e.digits.count == DurationEntry.capacity)
        #expect(e.duration?.seconds == TimerDuration.range.upperBound)
        #expect(DurationEntry().duration == nil)
        #expect(Digit("7") == .seven)
        #expect(Digit("٣") == nil)
    }
}

@Suite struct Geometry {
    @Test func theNotchIsTheGapBetweenTheAuxiliaryAreas() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let g = NotchGeometry(screenFrame: frame, topInset: 32,
                              auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                              auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
        #expect(g.hasHardwareNotch)
        #expect(g.notch == CGRect(x: 662, y: 950, width: 188, height: 32))
    }

    @Test func aScreenWithoutANotchGetsAPillAtTheTopCentre() {
        let frame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let g = NotchGeometry(screenFrame: frame, topInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        #expect(!g.hasHardwareNotch)
        #expect(g.notch.midX == frame.midX)
        #expect(g.notch.maxY == frame.maxY)
    }

    @Test func theCanvasHoldsEveryLayoutFlushWithTheTop() {
        for layout in NotchLayout.allCases {
            let r = geometry.activeRect(for: layout)
            #expect(geometry.canvas.contains(r))
            #expect(r.maxY == geometry.screenFrame.maxY)
            #expect(r.midX == geometry.notch.midX)
        }
        #expect(geometry.activeRect(for: .expanded).contains(inPanel))
    }
}

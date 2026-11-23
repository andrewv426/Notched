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

private func openState() -> NotchState {
    var s = NotchState(geometry: geometry, now: t0)
    s.reduce(.pointerDown(onNotch), at: t0)
    return s
}

/// Opens the notch, types `minutes` as a custom length and presses Return.
private func runCustom(_ s: inout NotchState, minutes: Int, at now: Instant) {
    s.reduce(.pointerDown(onNotch), at: now)
    s.reduce(.select(.custom), at: now)
    for c in String(minutes) { s.reduce(.key(.digit(Digit(c)!)), at: now) }
    s.reduce(.key(.submit), at: now)
}

private func minutes(_ m: Int) -> Duration { .seconds(m * 60) }

@Suite struct Countdowns {
    @Test func startRunsTheSelectedPhaseAndFinishesAtItsDeadline() {
        var s = openState()
        #expect(s.selection == .focus(.fifty))
        s.reduce(.timer(.start), at: t0)
        #expect(s.nextDeadline == t0.advanced(by: minutes(50)))
        #expect(s.countdown.readout(at: at(500)).text == "50:00")
        s.reduce(.pointerDown(farAway), at: at(1_000))
        s.reduce(.tick, at: t0.advanced(by: minutes(51)))
        #expect(s.ringing?.deadline == t0.advanced(by: minutes(50)))
        #expect(s.layout == .alert)
    }

    @Test func pauseAfterTheDeadlineDoesNotBringTheTimerBack() {
        var s = NotchState(geometry: geometry, now: t0)
        runCustom(&s, minutes: 1, at: t0)
        s.reduce(.timer(.pause), at: at(61_000))   // the alarm has not fired yet
        guard case .finished = s.countdown else { Issue.record("expected finished, got \(s.countdown)"); return }
    }

    @Test func pauseKeepsTheExactRemainderAndResumeMovesTheDeadline() {
        var s = NotchState(geometry: geometry, now: t0)
        runCustom(&s, minutes: 1, at: t0)
        s.reduce(.timer(.pause), at: at(10_250))
        #expect(s.countdown.remaining(at: at(99_000)) == .milliseconds(49_750))
        #expect(s.nextDeadline == nil)
        s.reduce(.timer(.resume), at: at(20_000))
        #expect(s.nextDeadline == at(69_750))
    }

    @Test func replayingAnEventConverges() {
        var once = NotchState(geometry: geometry, now: t0)
        runCustom(&once, minutes: 5, at: t0)
        once.reduce(.timer(.pause), at: at(10_000))
        var twice = once
        twice.reduce(.timer(.pause), at: at(20_000))
        twice.reduce(.tick, at: at(30_000))
        #expect(once == twice)
    }

    @Test func openingTheNotchStopsThePulseForGood() {
        var s = NotchState(geometry: geometry, now: t0)
        runCustom(&s, minutes: 1, at: t0)
        s.reduce(.pointerDown(farAway), at: at(10))
        s.reduce(.tick, at: at(60_000))
        #expect(s.ringing != nil)
        #expect(s.layout == .alert)
        s.reduce(.pointerDown(onNotch), at: at(61_000))
        #expect(s.ringing == nil)
        s.reduce(.pointerDown(farAway), at: at(62_000))
        #expect(s.layout == .dormant)
    }

    @Test func aTimerThatFinishesWhileTheNotchIsOpenStillPulsesAfterItCloses() {
        var s = NotchState(geometry: geometry, now: t0)
        runCustom(&s, minutes: 1, at: t0)
        s.reduce(.tick, at: at(60_000))
        #expect(s.layout == .expanded)
        #expect(s.ringing != nil)
        s.reduce(.pointerDown(farAway), at: at(61_000))
        #expect(s.layout == .alert)
    }

    @Test func readoutRoundsUpAndFormats() {
        #expect(Readout(wholeSeconds: 245).text == "4:05")
        #expect(Readout(wholeSeconds: 1500).text == "25:00")
        #expect(Readout(wholeSeconds: 3723).text == "1:02:03")
        var s = NotchState(geometry: geometry, now: t0)
        runCustom(&s, minutes: 1, at: t0)
        #expect(s.countdown.readout(at: at(59_900)).text == "0:01")
    }
}

@Suite struct Pomodoro {
    @Test func aFocusIsFollowedByItsBreakAndTheBreakByTheSameFocus() {
        var s = openState()
        s.reduce(.select(.focus(.twentyFive)), at: t0)
        s.reduce(.timer(.start), at: t0)
        s.reduce(.tick, at: t0.advanced(by: minutes(25)))
        #expect(s.countdown.phase == .focus(.twentyFive))
        #expect(s.selection == .rest)
        #expect(s.startable == TimerDuration(seconds: 5 * 60))
        s.reduce(.timer(.start), at: t0.advanced(by: minutes(26)))
        s.reduce(.tick, at: t0.advanced(by: minutes(31)))
        #expect(s.selection == .focus(.twentyFive))
    }

    @Test func theBreakAfterAFiftyMinuteFocusIsTenMinutes() {
        var s = openState()
        s.reduce(.timer(.start), at: t0)
        s.reduce(.tick, at: t0.advanced(by: minutes(50)))
        s.reduce(.timer(.start), at: t0.advanced(by: minutes(50)))
        #expect(s.countdown.phase == .rest)
        #expect(s.nextDeadline == t0.advanced(by: minutes(60)))
    }

    @Test func theNextPhaseIsChosenOnceEvenIfTheFinishIsSettledAgain() {
        var s = openState()
        s.reduce(.timer(.start), at: t0)
        s.reduce(.tick, at: t0.advanced(by: minutes(50)))
        s.reduce(.select(.focus(.fifty)), at: t0.advanced(by: minutes(51)))
        s.reduce(.tick, at: t0.advanced(by: minutes(52)))
        #expect(s.selection == .focus(.fifty))
    }

    @Test func aChoiceIsIgnoredWhileATimerRuns() {
        var s = openState()
        s.reduce(.timer(.start), at: t0)
        s.reduce(.select(.rest), at: at(10))
        #expect(s.selection == .focus(.fifty))
        #expect(s.countdown.phase == .focus(.fifty))
    }
}

@Suite struct Opening {
    @Test func hoveringDoesNotOpenAndAClickDoes() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(onNotch, dragging: false), at: t0)
        #expect(s.capturesPointer)
        #expect(s.nextDeadline == nil)
        s.reduce(.tick, at: at(5_000))
        #expect(s.layout == .dormant)
        s.reduce(.pointerDown(onNotch), at: at(5_100))
        #expect(s.layout == .expanded)
    }

    @Test func leavingTheOpenNotchClosesItAfterTheGrace() {
        var s = openState()
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(1_000))
        #expect(s.layout == .expanded)
        #expect(!s.capturesPointer)
        s.reduce(.pointerMoved(inPanel, dragging: false), at: at(1_200))   // overshoot and back
        s.reduce(.tick, at: at(1_700))
        #expect(s.layout == .expanded)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(2_000))
        s.reduce(.tick, at: at(2_450))
        #expect(s.layout == .dormant)
    }

    @Test func aPointerPushedAgainstTheTopEdgeIsOnTheNotch() {
        // Where the cursor stops when you push it up into the notch: y is exactly the screen's maxY.
        let topEdge = CGPoint(x: 756, y: geometry.screenFrame.maxY)
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(topEdge, dragging: false), at: t0)
        #expect(s.capturesPointer)
        s.reduce(.pointerDown(topEdge), at: t0)
        #expect(s.layout == .expanded)
    }

    @Test func draggingAcrossTheClosedNotchDoesNotTakeTheMouse() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(onNotch, dragging: true), at: t0)
        #expect(!s.capturesPointer)
    }

    @Test func movingWithinTheSameSideLeavesStateEqual() {
        var s = NotchState(geometry: geometry, now: t0)
        s.reduce(.pointerMoved(farAway, dragging: false), at: t0)
        var next = s
        next.reduce(.pointerMoved(CGPoint(x: 120, y: 140), dragging: false), at: at(8))
        #expect(next == s)
    }

    @Test func clickOutsideCloses() {
        var s = openState()
        s.reduce(.pointerDown(farAway), at: at(100))
        #expect(s.layout == .dormant)
    }
}

@Suite struct Custom {
    @Test func typedMinutesStartOnReturnAndBecomeTheCustomLength() {
        var s = openState()
        s.reduce(.select(.custom), at: t0)
        #expect(s.wantsKeyFocus)
        #expect(s.startable == nil)
        for d: Digit in [.zero, .four, .five] { s.reduce(.key(.digit(d)), at: t0) }
        #expect(s.entry.minutes == 45)
        s.reduce(.key(.submit), at: at(10))
        #expect(!s.wantsKeyFocus)
        #expect(s.custom == TimerDuration(seconds: 45 * 60))
        #expect(s.nextDeadline == at(10).advanced(by: minutes(45)))
    }

    @Test func escapeWithNothingTypedFallsBackToFocus() {
        var s = openState()
        s.reduce(.select(.custom), at: t0)
        s.reduce(.key(.cancel), at: at(100))
        #expect(!s.surface.isOpen)
        #expect(s.selection == .focus(.fifty))
    }

    @Test func pointerExitIsIgnoredWhileTyping() {
        var s = openState()
        s.reduce(.select(.custom), at: t0)
        s.reduce(.pointerMoved(farAway, dragging: false), at: at(100))
        s.reduce(.tick, at: at(5_000))
        #expect(s.surface.mode == .editing)
        s.reduce(.keyFocusLost, at: at(6_000))
        #expect(!s.surface.isOpen)   // outside for longer than the grace: closes at once
    }

    @Test func choosingAnotherPhaseStopsTyping() {
        var s = openState()
        s.reduce(.select(.custom), at: t0)
        s.reduce(.select(.rest), at: at(10))
        #expect(!s.wantsKeyFocus)
        #expect(s.selection == .rest)
    }

    @Test func entryCaps() {
        var e = DurationEntry()
        e.push(.zero)
        #expect(e.digits.isEmpty)
        for _ in 0..<5 { e.push(.nine) }
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

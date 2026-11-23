import CoreGraphics

/// Everything that can happen to the app, from any source: views, mouse monitors, the panel's key
/// status, screen changes, the alarm. The only way to change `NotchState`.
public enum NotchEvent: Equatable, Sendable {
    /// Pointer position in global AppKit coordinates (`NSEvent.mouseLocation`). `dragging` is true
    /// while a mouse button is held, so dragging a window past the notch does not open it.
    case pointerMoved(CGPoint, dragging: Bool)
    case pointerDown(CGPoint)
    /// The panel resigned key (Cmd-Tab, a click in another app's window).
    case keyFocusLost

    /// A choice in the open notch: a focus length, the break, or Custom (which starts typing).
    /// Ignored while a timer runs or is paused.
    case select(Phase)
    case key(EntryKey)
    /// Timer controls. `.start` runs the selected phase, or the typed custom length.
    case timer(TimerAction)
    /// Starts a given length as a phase, ignored while a timer runs or is paused. The views start
    /// through `.timer(.start)`; this lets a script run a timer of a few seconds.
    case run(TimerDuration, Phase)

    case screensChanged(NotchGeometry)
    /// "Time has passed." Sent by the deadline alarm and on wake from sleep. It does nothing by
    /// itself; it exists to trigger the settle that follows every event.
    case tick
}

public enum EntryKey: Equatable, Sendable {
    case digit(Digit)
    case backspace
    /// Return: start the typed length and stop editing.
    case submit
    /// Esc: stop editing and close.
    case cancel
}

public enum TimerAction: Equatable, Sendable {
    case start, pause, resume, reset
}

/// The whole app as one value. `reduce` is the only mutator. Every side effect is a projection the
/// shell matches after each event (`layout`, `nextDeadline`, `wantsKeyFocus`, `capturesPointer`,
/// `ringing`): there are no effect values and no callbacks out of the domain, so replaying an event
/// or reconciling twice converges.
public struct NotchState: Equatable, Sendable {
    public private(set) var countdown: Countdown
    public private(set) var entry: DurationEntry
    public private(set) var surface: Surface
    public private(set) var geometry: NotchGeometry
    /// The phase the open notch offers to start. While a run is going it is that run's phase, and
    /// when a run finishes it moves on to the phase that follows.
    public private(set) var selection: Phase
    /// The focus length the break follows, and that follows the break.
    public private(set) var lastFocus: FocusLength
    /// The last custom length started. Nil until one is typed.
    public private(set) var custom: TimerDuration?

    public init(geometry: NotchGeometry, now: Instant) {
        countdown = .idle
        entry = DurationEntry()
        surface = Surface(now: now)
        self.geometry = geometry
        selection = .focus(.fifty)
        lastFocus = .fifty
        custom = nil
    }

    /// Applies one event, then settles every time-based rule against `now`, in this order:
    /// countdown (and the phase that follows a run that just finished), surface, then "opening the
    /// notch acknowledges Done". Only the opening counts: a timer that finishes while the notch is
    /// already open still pulses once it closes.
    public mutating func reduce(_ event: NotchEvent, at now: Instant) {
        let wasOpen = surface.isOpen
        let before = countdown
        switch event {
        case .pointerMoved(let p, let dragging):
            // A drag over the closed notch is someone moving a window, not asking for the timer.
            surface.pointerMoved(inside: isOnShape(p) && !(dragging && !surface.isOpen), at: now)
        case .pointerDown(let p):
            let inside = isOnShape(p)
            surface.pointerMoved(inside: inside, at: now)
            surface.pointerDown(inside: inside)
        case .keyFocusLost:
            surface.endEditing()
        case .select(let phase):
            guard countdown.acceptsNewDuration else { break }
            countdown.apply(.reset, at: now)
            selection = phase
            if phase == .custom {
                entry = DurationEntry()
                surface.beginEditing()
            } else {
                surface.endEditing()
            }
        case .key(let key):
            guard surface.mode == .editing else { break }
            switch key {
            case .digit(let d): entry.push(d)
            case .backspace: entry.popLast()
            case .submit: start(at: now)
            case .cancel: surface.close()
            }
        case .timer(.start): start(at: now)
        case .timer(.pause): countdown.apply(.pause, at: now)
        case .timer(.resume): countdown.apply(.resume, at: now)
        case .timer(.reset): countdown.apply(.reset, at: now)
        case .run(let d, let phase):
            guard countdown.acceptsNewDuration else { break }
            surface.endEditing()
            selection = phase
            countdown.apply(.reset, at: now)
            countdown.apply(.start(d, phase), at: now)
        case .screensChanged(let g):
            geometry = g
        case .tick:
            break
        }
        countdown.settle(at: now)
        if case .running = before, case .finished(let f) = countdown {
            if case .focus(let length) = f.phase { lastFocus = length }
            selection = f.phase.next(lastFocus: lastFocus)
        }
        surface.settle(at: now)
        // Custom with nothing typed is not a choice once typing ends.
        if selection == .custom, custom == nil, surface.mode != .editing { selection = .focus(lastFocus) }
        if surface.isOpen, !wasOpen { countdown.acknowledge() }
    }

    // MARK: Projections the shell reconciles

    public var layout: NotchLayout {
        if surface.isOpen { return .expanded }
        switch countdown {
        case .idle: return .dormant
        case .running, .paused: return .glance
        case .finished(let f): return f.acknowledged ? .dormant : .alert
        }
    }

    /// The shape's current rect on screen.
    public var activeRect: CGRect { geometry.activeRect(for: layout) }

    /// Whether a pointer position is on the shape. The top edge counts: a pointer pushed up into the
    /// notch rests at exactly `screenFrame.maxY`, which `CGRect.contains` treats as outside.
    func isOnShape(_ p: CGPoint) -> Bool {
        let r = activeRect
        return p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    /// The one wake-up the shell keeps armed: the earlier of the countdown's deadline and the
    /// surface's grace deadline. When it fires, the shell sends `.tick`.
    public var nextDeadline: Instant? {
        [countdown.deadline, surface.deadline].compactMap { $0 }.min()
    }

    /// The panel is key exactly while the user is typing a custom length.
    public var wantsKeyFocus: Bool { surface.mode == .editing }

    /// `panel.ignoresMouseEvents = !capturesPointer`. The same rect as the click target, so the
    /// window takes clicks exactly where the black shape is and nowhere else on the menu bar.
    public var capturesPointer: Bool { surface.isPointerInside }

    /// Non-nil while a finished run should pulse. Once acknowledged it never comes back for the same
    /// run, so closing the notch again does not pulse again.
    public var ringing: Countdown.Finished? {
        if case .finished(let f) = countdown, !f.acknowledged { return f }
        return nil
    }

    /// The length a phase runs for. Nil only for Custom before anything was typed.
    public func duration(of phase: Phase) -> TimerDuration? {
        switch phase {
        case .focus(let length): length.duration
        case .rest: lastFocus.rest
        case .custom: custom
        }
    }

    /// What Start runs now: the length being typed, or the selected phase's.
    public var startable: TimerDuration? {
        surface.mode == .editing ? entry.duration : duration(of: selection)
    }

    /// Starts `startable`, committing a typed length as the custom one.
    mutating func start(at now: Instant) {
        if surface.mode == .editing {
            guard let typed = entry.duration else { return }
            custom = typed
            surface.endEditing()
        }
        guard let d = duration(of: selection), countdown.acceptsNewDuration else { return }
        countdown.apply(.start(d, selection), at: now)
    }
}

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

    /// The user clicked the HH:MM:SS display. Ignored unless the countdown takes a new duration.
    case beginEditing
    case key(EntryKey)
    /// Sets the entry to the preset and starts it: one click from a closed notch to a running timer.
    case preset(TimerDuration)
    /// Timer controls. `.start` runs the current entry.
    case timer(TimerAction)

    case screensChanged(NotchGeometry)
    /// "Time has passed." Sent by the deadline alarm and on wake from sleep. It does nothing by
    /// itself; it exists to trigger the settle that follows every event.
    case tick
}

public enum EntryKey: Equatable, Sendable {
    case digit(Digit)
    case backspace
    /// Return: start the entry and stop editing.
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

    public init(geometry: NotchGeometry, now: Instant) {
        countdown = .idle
        entry = DurationEntry()
        surface = Surface(now: now)
        self.geometry = geometry
    }

    /// Applies one event, then settles every time-based rule against `now`, in this order:
    /// countdown, surface, then "opening the notch silences Done". Only the opening counts: a timer
    /// that finishes while the notch is already open still rings.
    public mutating func reduce(_ event: NotchEvent, at now: Instant) {
        let wasOpen = surface.isOpen
        switch event {
        case .pointerMoved(let p, let dragging):
            // A drag over the closed notch is someone moving a window, not asking for the timer.
            let inside = isOnShape(p) && !(dragging && !surface.isOpen)
            surface.pointerMoved(inside: inside, at: now)
        case .pointerDown(let p):
            let inside = isOnShape(p)
            surface.pointerMoved(inside: inside, at: now)
            surface.pointerDown(inside: inside, at: now)
        case .keyFocusLost:
            surface.endEditing()
        case .beginEditing:
            guard countdown.acceptsNewDuration else { break }
            countdown.apply(.reset, at: now)
            surface.beginEditing()
        case .key(let key):
            guard surface.mode == .editing else { break }
            switch key {
            case .digit(let d): entry.push(d)
            case .backspace: entry.popLast()
            case .submit:
                startEntry(at: now)
                surface.endEditing()
            case .cancel: surface.close(at: now)
            }
        case .preset(let d):
            guard countdown.acceptsNewDuration else { break }
            entry = DurationEntry(d)
            startEntry(at: now)
        case .timer(.start):
            startEntry(at: now)
        case .timer(.pause): countdown.apply(.pause, at: now)
        case .timer(.resume): countdown.apply(.resume, at: now)
        case .timer(.reset): countdown.apply(.reset, at: now)
        case .screensChanged(let g):
            geometry = g
        case .tick:
            break
        }
        countdown.settle(at: now)
        surface.settle(at: now)
        if surface.isOpen, !wasOpen { countdown.acknowledge() }
    }

    // MARK: Projections the shell reconciles

    public var layout: NotchLayout {
        if surface.isOpen { return .expanded }
        switch countdown {
        case .idle: return .dormant
        case .running, .paused: return .glance
        case .finished: return .alert
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
    /// surface's dwell or grace deadline. When it fires, the shell sends `.tick`.
    public var nextDeadline: Instant? {
        [countdown.deadline, surface.deadline].compactMap { $0 }.min()
    }

    /// The panel is key exactly while the user is typing a duration.
    public var wantsKeyFocus: Bool { surface.mode == .editing }

    /// `panel.ignoresMouseEvents = !capturesPointer`. The same rect as hover, so the window takes
    /// clicks exactly where the black shape is and nowhere else on the menu bar.
    public var capturesPointer: Bool { surface.isPointerInside }

    /// Non-nil while the completion alert should sound. Once acknowledged it never comes back for
    /// the same run, so closing the notch again does not ring again.
    public var ringing: Countdown.Finished? {
        if case .finished(let f) = countdown, !f.acknowledged { return f }
        return nil
    }

    /// Starts the entry if it is not zero.
    mutating func startEntry(at now: Instant) {
        guard let d = entry.duration, countdown.acceptsNewDuration else { return }
        countdown.apply(.start(d), at: now)
    }
}

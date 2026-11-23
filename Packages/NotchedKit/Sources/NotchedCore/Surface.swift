/// Whether the notch is open, and why. Owns hover intent, the leave grace period and the edit lock.
/// All of its timing is timestamps in state: `deadline` is the next instant it changes on its own,
/// and the shell keeps one wake-up armed for it. There are no timers in the domain.
public struct Surface: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Closed. Remembers when, so a pointer already resting on the notch at that moment (Esc,
        /// Return, a click outside then back) does not reopen it after the dwell: the pointer has
        /// to leave and come back. Reopening needs `pointer.inside(since: s)` with `s >= at`.
        case closed(at: Instant)
        /// Open for looking and clicking buttons. Never key, so it never takes keystrokes from the
        /// app the user is typing in. Closes `grace` after the pointer leaves.
        case browsing
        /// Open and key, for typing a duration. Pointer exit is ignored. Ends on Return (→ browsing),
        /// Esc or a click outside (→ closed), or loss of key focus (→ browsing).
        case editing
    }

    /// The pointer's side of the notch shape, and since when. It changes only on a crossing, so a
    /// stream of 120 Hz mouse moves leaves this value, and SwiftUI, untouched.
    public enum Pointer: Equatable, Sendable {
        case inside(since: Instant)
        case outside(since: Instant)
    }

    public internal(set) var mode: Mode
    public internal(set) var pointer: Pointer

    /// The pointer must rest this long before the notch opens, so a sweep to the menu bar does not flash it.
    public static let dwell: Duration = .milliseconds(120)
    /// Leaving the open notch closes it after this long, so a slight overshoot does not.
    public static let grace: Duration = .milliseconds(450)

    init(now: Instant) {
        mode = .closed(at: now)
        pointer = .outside(since: now)
    }

    public var isOpen: Bool {
        if case .closed = mode { return false }
        return true
    }

    public var isPointerInside: Bool {
        if case .inside = pointer { return true }
        return false
    }

    /// The next instant this value changes without input:
    ///   closed(at: c) and inside(since: s) with s >= c → s + dwell (opens)
    ///   browsing and outside(since: s)                 → s + grace (closes)
    var deadline: Instant? {
        switch (mode, pointer) {
        case (.closed(let c), .inside(let s)) where s >= c: s.advanced(by: Self.dwell)
        case (.browsing, .outside(let s)): s.advanced(by: Self.grace)
        default: nil
        }
    }

    /// Records a crossing. The same side as before changes nothing (and keeps `since`).
    mutating func pointerMoved(inside: Bool, at now: Instant) {
        guard inside != isPointerInside else { return }
        pointer = inside ? .inside(since: now) : .outside(since: now)
    }

    /// A click on the closed notch opens it at once (no dwell). A click outside the open notch closes it.
    mutating func pointerDown(inside: Bool, at now: Instant) {
        if inside, !isOpen {
            mode = .browsing
        } else if !inside, isOpen {
            close(at: now)
        }
    }

    /// browsing → editing. NotchState checks that the countdown takes a new duration.
    mutating func beginEditing() {
        if mode == .browsing { mode = .editing }
    }

    /// editing → browsing. If the pointer has been outside for longer than `grace`, the settle that
    /// follows every event closes the notch at once: press Return with the cursor away and it
    /// collapses straight into the running readout.
    mutating func endEditing() {
        if mode == .editing { mode = .browsing }
    }

    /// Any open mode → closed.
    mutating func close(at now: Instant) {
        if isOpen { mode = .closed(at: now) }
    }

    /// Applies whichever deadline has passed. Idempotent.
    mutating func settle(at now: Instant) {
        guard let deadline, now >= deadline else { return }
        switch mode {
        case .closed: mode = .browsing
        case .browsing: mode = .closed(at: deadline)
        case .editing: break
        }
    }
}

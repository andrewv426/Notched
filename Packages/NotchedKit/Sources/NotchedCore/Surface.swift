/// Whether the notch is open, and why. A click opens it; once open, the pointer leaving closes it
/// after a grace period, unless the user is typing. The timing is a timestamp in state: `deadline`
/// is the next instant it changes on its own, and the shell keeps one wake-up armed for it. There
/// are no timers in the domain.
public struct Surface: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case closed
        /// Open for looking and clicking buttons. Never key, so it never takes keystrokes from the
        /// app the user is typing in. Closes `grace` after the pointer leaves.
        case browsing
        /// Open and key, for typing a custom length. Pointer exit is ignored. Ends on Return
        /// (→ browsing), Esc or a click outside (→ closed), or loss of key focus (→ browsing).
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

    /// Leaving the open notch closes it after this long, so a slight overshoot does not.
    public static let grace: Duration = .milliseconds(450)

    init(now: Instant) {
        mode = .closed
        pointer = .outside(since: now)
    }

    public var isOpen: Bool { mode != .closed }

    public var isPointerInside: Bool {
        if case .inside = pointer { return true }
        return false
    }

    /// While browsing with the pointer outside since `s`, the notch closes at `s + grace`.
    var deadline: Instant? {
        if mode == .browsing, case .outside(let s) = pointer { return s.advanced(by: Self.grace) }
        return nil
    }

    /// Records a crossing. The same side as before changes nothing (and keeps `since`).
    mutating func pointerMoved(inside: Bool, at now: Instant) {
        guard inside != isPointerInside else { return }
        pointer = inside ? .inside(since: now) : .outside(since: now)
    }

    /// A click on the closed notch opens it. A click outside the open notch closes it.
    mutating func pointerDown(inside: Bool) {
        if inside, !isOpen {
            mode = .browsing
        } else if !inside, isOpen {
            mode = .closed
        }
    }

    /// Open → editing. NotchState checks that the countdown takes a new duration.
    mutating func beginEditing() {
        if isOpen { mode = .editing }
    }

    /// editing → browsing. If the pointer has been outside for longer than `grace`, the settle that
    /// follows every event closes the notch at once: press Return with the cursor away and it
    /// collapses straight into the running readout.
    mutating func endEditing() {
        if mode == .editing { mode = .browsing }
    }

    mutating func close() { mode = .closed }

    /// Closes the notch once the grace period has passed. Idempotent.
    mutating func settle(at now: Instant) {
        if let deadline, now >= deadline { mode = .closed }
    }
}

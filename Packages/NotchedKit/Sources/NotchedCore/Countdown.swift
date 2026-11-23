// No clock is read in NotchedCore. Every rule that depends on time takes `now` as an argument.

/// The one clock the app uses. On Darwin `ContinuousClock` keeps advancing while the Mac sleeps
/// and ignores wall-clock changes, so a 25-minute timer means 25 real minutes even across a
/// closed lid: sleep does not pause the timer.
public typealias Instant = ContinuousClock.Instant

/// A positive, bounded timer length. Only a validating init exists, so every countdown can start.
/// The upper bound is exactly the largest value a `DurationEntry` can spell (999 minutes), so
/// "the entry can start" is the same as "the entry is not zero".
public struct TimerDuration: Hashable, Comparable, Sendable {
    public static let range: ClosedRange<Int> = 1...(999 * 60)

    public let seconds: Int

    public init?(seconds: Int) {
        guard Self.range.contains(seconds) else { return nil }
        self.seconds = seconds
    }

    public var duration: Duration { .seconds(seconds) }

    public static func < (a: Self, b: Self) -> Bool { a.seconds < b.seconds }
}

/// The single timer's lifecycle. Payload inits are internal, so code outside NotchedCore can
/// match a `.paused(p)` but never build one with a negative `remaining`.
public enum Countdown: Equatable, Sendable {
    case idle
    case running(Running)
    case paused(Paused)
    /// Stays here until the user resets or starts again. `acknowledged` stops the pulse without
    /// leaving the state, so the open notch can still say which phase just ended.
    case finished(Finished)

    public struct Running: Equatable, Sendable {
        public let total: TimerDuration
        public let phase: Phase
        /// The source of truth while running. Remaining time is derived from it, never decremented.
        public let deadline: Instant
    }

    public struct Paused: Equatable, Sendable {
        public let total: TimerDuration
        public let phase: Phase
        /// Always `.zero < remaining <= total.duration`: a pause at or after the deadline
        /// finishes the timer instead (`apply` settles first).
        public let remaining: Duration
    }

    public struct Finished: Equatable, Sendable {
        public let total: TimerDuration
        public let phase: Phase
        /// When the run ended.
        public let deadline: Instant
        public internal(set) var acknowledged = false
    }
}

enum TimerCommand: Equatable, Sendable {
    case start(TimerDuration, Phase)
    case pause
    case resume
    case reset
}

extension Countdown {
    /// Total over every (state, command) pair; a command that does not apply does nothing, so
    /// double clicks and a button racing the alarm are harmless. It settles first, so a pause that
    /// arrives after the deadline but before the alarm fired cannot bring a finished timer back.
    ///
    ///   state     | start(d)          | pause                | resume                 | reset
    ///   idle      | running(now + d)  | –                    | –                      | –
    ///   running   | –                 | paused(deadline-now) | –                      | idle
    ///   paused    | –                 | –                    | running(now+remaining) | idle
    ///   finished  | running(now + d)  | –                    | –                      | idle
    mutating func apply(_ command: TimerCommand, at now: Instant) {
        settle(at: now)
        switch (self, command) {
        case (.idle, .start(let d, let phase)), (.finished, .start(let d, let phase)):
            self = .running(Running(total: d, phase: phase, deadline: now.advanced(by: d.duration)))
        case (.running(let r), .pause):
            self = .paused(Paused(total: r.total, phase: r.phase, remaining: now.duration(to: r.deadline)))
        case (.paused(let p), .resume):
            self = .running(Running(total: p.total, phase: p.phase, deadline: now.advanced(by: p.remaining)))
        case (.running, .reset), (.paused, .reset), (.finished, .reset):
            self = .idle
        default:
            break
        }
    }

    /// A running timer whose deadline has passed becomes finished at its *deadline*, not at `now`,
    /// so a late alarm or a wake from sleep records when it really ended. Every other state is
    /// unchanged, so this is safe to call from any trigger, any number of times.
    mutating func settle(at now: Instant) {
        if case .running(let r) = self, now >= r.deadline {
            self = .finished(Finished(total: r.total, phase: r.phase, deadline: r.deadline))
        }
    }

    /// Stops a finished run's pulse. Does nothing in every other state.
    mutating func acknowledge() {
        if case .finished(var f) = self, !f.acknowledged {
            f.acknowledged = true
            self = .finished(f)
        }
    }

    /// When this countdown next changes on its own. Non-nil only while running.
    public var deadline: Instant? {
        if case .running(let r) = self { return r.deadline }
        return nil
    }

    /// Idle and finished timers take a new duration; running and paused ones must be reset first.
    public var acceptsNewDuration: Bool {
        switch self {
        case .idle, .finished: true
        case .running, .paused: false
        }
    }

    /// The phase of the current or last run. Idle: nil.
    public var phase: Phase? {
        switch self {
        case .idle: nil
        case .running(let r): r.phase
        case .paused(let p): p.phase
        case .finished(let f): f.phase
        }
    }

    public var total: TimerDuration? {
        switch self {
        case .idle: nil
        case .running(let r): r.total
        case .paused(let p): p.total
        case .finished(let f): f.total
        }
    }

    /// Clamped to `.zero...total`. Running: deadline − now. Paused: the stored remainder.
    public func remaining(at now: Instant) -> Duration {
        switch self {
        case .idle, .finished: .zero
        case .running(let r): min(max(.zero, now.duration(to: r.deadline)), r.total.duration)
        case .paused(let p): p.remaining
        }
    }

    /// The share of the run still left, 1 → 0. Drives the progress ring. Idle: 0.
    public func fractionRemaining(at now: Instant) -> Double {
        guard let total, case let left = remaining(at: now) else { return 0 }
        return left.seconds / total.duration.seconds
    }

    /// The one rounding rule for every number on screen: whole seconds rounded up, so the display
    /// reads 0:01 until the instant the timer finishes and never 0:00 while it runs.
    public func readout(at now: Instant) -> Readout {
        Readout(wholeSeconds: Int(remaining(at: now).seconds.rounded(.up)))
    }
}

/// Remaining time as text. The collapsed wings and the open panel both render this, so they
/// cannot disagree about rounding or format.
public struct Readout: Equatable, Sendable {
    public let wholeSeconds: Int

    public init(wholeSeconds: Int) { self.wholeSeconds = max(0, wholeSeconds) }

    /// "4:05", "25:00", "1:02:03". No leading zero on the first field.
    public var text: String {
        let h = wholeSeconds / 3600, m = wholeSeconds / 60 % 60, s = wholeSeconds % 60
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
    }
}

extension Duration {
    /// Seconds as a floating-point number, for ratios and rounding.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

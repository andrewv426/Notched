/// The duration the user is typing, entered like a microwave: digits fill HH:MM:SS from the right
/// ("2", "5", "0", "0" → 00:25:00). There is no free-text field and so no parse-error state: every
/// buffer is either zero (Start disabled) or a valid `TimerDuration`.
///
/// This is the only record of what Start will run. Presets overwrite it and Restart reuses it.
public struct DurationEntry: Equatable, Sendable {
    public static let capacity = 6

    /// Most significant first. Never more than `capacity`, never a leading zero.
    public private(set) var digits: [Digit]

    public init() { digits = [] }

    /// Spells a duration as digits, normalised: 90 s → 1:30, not 0:90.
    public init(_ duration: TimerDuration) {
        let s = duration.seconds
        let value = (s / 3600) * 10_000 + (s / 60 % 60) * 100 + s % 60
        digits = String(value).compactMap { Digit($0) }
    }

    /// Appends a digit. Ignored when full, or when it would be a leading zero.
    mutating func push(_ digit: Digit) {
        guard digits.count < Self.capacity, !(digits.isEmpty && digit == .zero) else { return }
        digits.append(digit)
    }

    /// Removes the last digit. Does nothing when empty.
    mutating func popLast() {
        if !digits.isEmpty { digits.removeLast() }
    }

    /// The fields as displayed, each 0...99. "90" in the seconds slot stays 90 here; it becomes
    /// 1:30 only in `duration`.
    public var fields: (hours: Int, minutes: Int, seconds: Int) {
        let value = digits.reduce(0) { $0 * 10 + $1.rawValue }
        return (value / 10_000, value / 100 % 100, value % 100)
    }

    /// Nil exactly when every digit is zero. Total by construction: the largest entry, 99:99:99,
    /// is `TimerDuration.range.upperBound`.
    public var duration: TimerDuration? {
        let f = fields
        return TimerDuration(seconds: f.hours * 3600 + f.minutes * 60 + f.seconds)
    }
}

public enum Digit: Int, Sendable, CaseIterable {
    case zero, one, two, three, four, five, six, seven, eight, nine

    /// Boundary parse for key presses. Only ASCII 0–9.
    public init?(_ character: Character) {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return nil }
        self.init(rawValue: Int(ascii) - 48)
    }
}

/// The custom length the user is typing, in whole minutes ("4", "5" → 45 minutes). There is no
/// free-text field and so no parse-error state: every buffer is either zero (Start disabled) or a
/// valid `TimerDuration`.
public struct DurationEntry: Equatable, Sendable {
    public static let capacity = 3

    /// Most significant first. Never more than `capacity`, never a leading zero.
    public private(set) var digits: [Digit]

    public init() { digits = [] }

    /// Appends a digit. Ignored when full, or when it would be a leading zero.
    mutating func push(_ digit: Digit) {
        guard digits.count < Self.capacity, !(digits.isEmpty && digit == .zero) else { return }
        digits.append(digit)
    }

    /// Removes the last digit. Does nothing when empty.
    mutating func popLast() {
        if !digits.isEmpty { digits.removeLast() }
    }

    public var minutes: Int { digits.reduce(0) { $0 * 10 + $1.rawValue } }

    /// Nil exactly when the entry is empty. Total by construction: the largest entry, 999 minutes,
    /// is `TimerDuration.range.upperBound`.
    public var duration: TimerDuration? { TimerDuration(seconds: minutes * 60) }
}

public enum Digit: Int, Sendable, CaseIterable {
    case zero, one, two, three, four, five, six, seven, eight, nine

    /// Boundary parse for key presses. Only ASCII 0–9.
    public init?(_ character: Character) {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return nil }
        self.init(rawValue: Int(ascii) - 48)
    }
}

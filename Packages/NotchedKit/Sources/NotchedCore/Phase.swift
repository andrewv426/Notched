/// What a run is for. Focus phases come in two lengths, and each pairs with its own break: 10
/// minutes after a 50-minute focus, 5 after a 25-minute one.
public enum Phase: Hashable, Sendable {
    case focus(FocusLength)
    case rest
    /// A length the user typed, in minutes.
    case custom

    /// The open notch's choices, in display order.
    public static let choices: [Phase] = [.focus(.fifty), .focus(.twentyFive), .rest, .custom]

    /// What comes after this phase finishes: a focus is followed by its break, a break by the focus
    /// it followed, and a custom run by another custom run.
    func next(lastFocus: FocusLength) -> Phase {
        switch self {
        case .focus: .rest
        case .rest: .focus(lastFocus)
        case .custom: .custom
        }
    }
}

public enum FocusLength: Int, Hashable, Sendable {
    case fifty = 50
    case twentyFive = 25

    public var duration: TimerDuration { TimerDuration(seconds: rawValue * 60)! }

    /// The break that follows a focus of this length.
    public var rest: TimerDuration { TimerDuration(seconds: (self == .fifty ? 10 : 5) * 60)! }
}

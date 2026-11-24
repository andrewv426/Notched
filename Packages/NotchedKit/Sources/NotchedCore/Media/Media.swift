/// The app that owns now playing: Spotify, Music, or the browser a tab plays in.
public struct Player: Equatable, Sendable {
    public let bundleID: String
    /// The app's name as the user knows it, resolved by the app from the bundle id.
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Names an artwork image. The bytes stay in the app's cache, so comparing states (on every event)
/// never compares hundreds of kilobytes.
public struct ArtworkKey: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct Track: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    /// Nil for a live stream or an unknown length: no scrubber, and seeking is not offered.
    public let duration: Duration?
    public let artwork: ArtworkKey?

    public init(title: String, artist: String? = nil, album: String? = nil, duration: Duration? = nil,
                artwork: ArtworkKey? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration.flatMap { $0 > .zero ? $0 : nil }
        self.artwork = artwork
    }
}

/// Where playback is. The position is derived from an anchor, never ticked, like `Countdown.running`.
public enum Playback: Equatable, Sendable {
    /// At `instant` the position was `elapsed`, moving at `rate` (> 0) seconds per second.
    case playing(elapsed: Duration, instant: Instant, rate: Double)
    case paused(at: Duration)

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// Unclamped: `NowPlaying.position(at:)` clamps to the track.
    func position(at now: Instant) -> Duration {
        switch self {
        case .playing(let elapsed, let instant, let rate): elapsed + instant.duration(to: now) * rate
        case .paused(let at): at
        }
    }

    /// Whether two reports describe the same playback at `now`: both playing at the same rate, or
    /// both paused, at positions within `tolerance`.
    func matches(_ other: Playback, at now: Instant, tolerance: Duration) -> Bool {
        switch (self, other) {
        case (.playing(_, _, let a), .playing(_, _, let b)) where a == b: break
        case (.paused, .paused): break
        default: return false
        }
        return abs((position(at: now) - other.position(at: now)).seconds) <= tolerance.seconds
    }
}

public struct NowPlaying: Equatable, Sendable {
    public let player: Player
    public let track: Track
    public internal(set) var playback: Playback

    public init(player: Player, track: Track, playback: Playback) {
        self.player = player
        self.track = track
        if case .playing(let e, let i, let rate) = playback, !(rate > 0) {
            self.playback = .playing(elapsed: e, instant: i, rate: 1)
        } else {
            self.playback = playback
        }
    }

    public var isPlaying: Bool { playback.isPlaying }

    /// Clamped to `0...duration` (or to 0 and up without a duration).
    public func position(at now: Instant) -> Duration {
        let p = max(.zero, playback.position(at: now))
        return track.duration.map { min(p, $0) } ?? p
    }

    /// 0 → 1 through the track. Nil without a duration.
    public func fractionPlayed(at now: Instant) -> Double? {
        track.duration.map { position(at: now).seconds / $0.seconds }
    }

    public var canSeek: Bool { track.duration != nil }
}

/// The Mac's output volume (the default output device), not a player's own.
public struct OutputVolume: Equatable, Sendable {
    /// 0...1.
    public let level: Double
    public let isMuted: Bool

    public init(level: Double, isMuted: Bool) {
        self.level = level.isNaN ? 0 : min(max(level, 0), 1)
        self.isMuted = isMuted
    }
}

/// What a view asks of the player.
public enum MediaAction: Equatable, Sendable {
    case togglePlayPause
    case stop
    case next
    case previous
    case seek(to: Duration)
    /// Sets the level and unmutes.
    case setVolume(Double)
}

/// What the app tells the player or the audio device, decided by the domain. Toggle is already
/// resolved against the known state, so the player gets an explicit play or pause.
public enum MediaCommand: Equatable, Sendable {
    case play, pause, stop, next, previous
    case seek(to: Duration)
    case setVolume(Double)
}

/// The last command the domain issued. `id` is its identity for the shell, as `AgentFocusRequest.at`
/// is for the Focuser: reflecting the same request twice sends it once.
public struct MediaRequest: Equatable, Sendable {
    public let id: Int
    public let command: MediaCommand
}

/// Music's part of `NotchState`: the source's last report, the user's commands, and whether the
/// closed notch shows it. The mutators are internal; only `NotchState.reduce` calls them.
public struct Media: Equatable, Sendable {
    /// Paused music keeps the wings this long, so a pause is visible before the notch goes bare.
    public static let linger: Duration = .seconds(5)
    /// A report of "nothing playing" waits this long before it counts, which bridges the gap
    /// some players leave between tracks.
    public static let vanishGrace: Duration = .milliseconds(1_500)
    /// How long the play state or position a command expects wins over contradicting reports.
    public static let confirmTimeout: Duration = .seconds(2)
    /// Reports that predict the same position within this are the same state.
    public static let positionTolerance: Duration = .milliseconds(500)

    /// What the source said last, kept through `vanishGrace` after it says nothing plays.
    var reported: NowPlaying?
    var vanishedAt: Instant?
    /// The playback a command just asked for, shown until the source agrees or `until` passes, so a
    /// click shows at once and a command that silently fails reverts by itself.
    var expected: Expectation?
    public private(set) var volume: OutputVolume?
    public private(set) var request: MediaRequest?
    /// Whether the closed notch shows music: playing, or paused less than `linger` ago. Stored and
    /// settled, because `layout` takes no `now`.
    public private(set) var isShowing = false
    var quietSince: Instant?

    struct Expectation: Equatable, Sendable {
        let playback: Playback
        let until: Instant
    }

    init() {}

    /// What is playing, with any expected change from a command applied.
    public var nowPlaying: NowPlaying? {
        guard var current = reported else { return nil }
        if let expected { current.playback = expected.playback }
        return current
    }

    // MARK: Changes, called only by `NotchState.reduce`

    mutating func report(_ next: NowPlaying?, at now: Instant) {
        guard let next else {
            if reported != nil, vanishedAt == nil { vanishedAt = now }
            return
        }
        vanishedAt = nil
        if let old = reported, old.player != next.player || old.track != next.track {
            expected = nil
        }
        if let e = expected, next.playback.matches(e.playback, at: now, tolerance: Self.positionTolerance) {
            expected = nil
        }
        // A periodic refresh that predicts the same position changes nothing, so it never reaches SwiftUI.
        if let old = reported, old.player == next.player, old.track == next.track,
           old.playback.matches(next.playback, at: now, tolerance: Self.positionTolerance) {
            return
        }
        reported = next
    }

    mutating func setOutputVolume(_ volume: OutputVolume?) {
        self.volume = volume
    }

    /// Drops what cannot apply: transport with nothing playing, a seek without a duration, a volume
    /// with no settable device.
    mutating func perform(_ action: MediaAction, at now: Instant) {
        if case .setVolume(let level) = action {
            guard volume != nil else { return }
            let set = OutputVolume(level: level, isMuted: false)
            volume = set
            issue(.setVolume(set.level))
            return
        }
        guard let current = nowPlaying else { return }
        let position = current.position(at: now)
        switch action {
        case .togglePlayPause where current.isPlaying, .stop:
            expect(.paused(at: position), at: now)
            issue(action == .stop ? .stop : .pause)
        case .togglePlayPause:
            expect(.playing(elapsed: position, instant: now, rate: 1), at: now)
            issue(.play)
        case .next: issue(.next)
        case .previous: issue(.previous)
        case .seek(let target):
            guard let duration = current.track.duration else { return }
            let clamped = min(max(target, .zero), duration)
            if case .playing(_, _, let rate) = current.playback {
                expect(.playing(elapsed: clamped, instant: now, rate: rate), at: now)
            } else {
                expect(.paused(at: clamped), at: now)
            }
            issue(.seek(to: clamped))
        case .setVolume:
            break
        }
    }

    /// Applies what time alone changes. Idempotent.
    mutating func settle(at now: Instant) {
        if let v = vanishedAt, now >= v.advanced(by: Self.vanishGrace) {
            reported = nil
            vanishedAt = nil
            expected = nil
        }
        if let e = expected, now >= e.until { expected = nil }
        if nowPlaying?.isPlaying == true {
            isShowing = true
            quietSince = nil
        } else if nowPlaying == nil {
            isShowing = false
            quietSince = nil
        } else if isShowing {
            let since = quietSince ?? now
            quietSince = since
            if now >= since.advanced(by: Self.linger) {
                isShowing = false
                quietSince = nil
            }
        }
    }

    /// The earliest instant this changes on its own.
    var deadline: Instant? {
        [vanishedAt?.advanced(by: Self.vanishGrace), expected?.until, quietSince?.advanced(by: Self.linger)]
            .compactMap { $0 }.min()
    }

    private mutating func expect(_ playback: Playback, at now: Instant) {
        expected = Expectation(playback: playback, until: now.advanced(by: Self.confirmTimeout))
    }

    private mutating func issue(_ command: MediaCommand) {
        request = MediaRequest(id: (request?.id ?? 0) + 1, command: command)
    }
}

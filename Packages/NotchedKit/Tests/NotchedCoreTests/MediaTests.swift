import CoreGraphics
import Testing
@testable import NotchedCore

private let t0 = ContinuousClock.now
private let wall0 = 1_800_000_000.0
private let geometry = NotchGeometry(
    screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    hardwareNotch: CGRect(x: 662, y: 950, width: 188, height: 32)
)
private let onNotch = CGPoint(x: 756, y: 970)
private let farAway = CGPoint(x: 100, y: 100)

private func secs(_ s: Double) -> Instant { t0.advanced(by: .seconds(s)) }

private let spotify = Player(bundleID: "com.spotify.client", name: "Spotify")

/// A track of `length` seconds (nil: a live stream), playing from `elapsed` at `at`, or paused there.
private func track(_ title: String = "Song", playing: Bool = true, elapsed: Double = 30, at: Double = 0,
                   length: Double? = 200, rate: Double = 1) -> NowPlaying {
    NowPlaying(player: spotify,
               track: Track(title: title, artist: "Artist", duration: length.map { .seconds($0) }),
               playback: playing ? .playing(elapsed: .seconds(elapsed), instant: secs(at), rate: rate)
                                 : .paused(at: .seconds(elapsed)))
}

private func launched() -> NotchState { NotchState(geometry: geometry, now: t0) }

private func playing(_ n: NowPlaying = track()) -> NotchState {
    var s = launched()
    s.reduce(.nowPlaying(n), at: t0)
    return s
}

@Suite struct Position {
    @Test func movesAtTheRateAndClampsToTheTrack() {
        let n = track(elapsed: 30, at: 0, length: 200, rate: 2)
        #expect(n.position(at: secs(10)) == .seconds(50))
        #expect(n.position(at: secs(1_000)) == .seconds(200))
        #expect(n.fractionPlayed(at: secs(10)) == 0.25)
    }

    @Test func pausedHoldsItsPositionAcrossASleepSizedGap() {
        let n = track(playing: false, elapsed: 42)
        #expect(n.position(at: secs(8 * 3600)) == .seconds(42))
    }

    @Test func aLiveStreamHasNoFractionAndCannotSeek() {
        let n = track(length: nil)
        #expect(n.fractionPlayed(at: secs(5)) == nil)
        #expect(!n.canSeek)
        #expect(n.position(at: secs(5)) == .seconds(35))
    }
}

@Suite struct MusicInTheNotch {
    @Test func playingMusicFillsTheWingsAndOpensItsPage() {
        var s = playing()
        #expect(s.wings == .music)
        #expect(s.layout == .music)
        #expect(s.pages == [.timer, .music])
        s.reduce(.pointerDown(onNotch), at: secs(1))
        #expect(s.page == .music)
    }

    @Test func pausedWingsLingerThenTheNotchGoesBare() {
        var s = playing()
        s.reduce(.nowPlaying(track(playing: false, elapsed: 40)), at: secs(10))
        #expect(s.layout == .music)
        #expect(s.nextDeadline == secs(10).advanced(by: Media.linger))
        s.reduce(.tick, at: secs(10).advanced(by: Media.linger))
        #expect(s.layout == .dormant)
        #expect(s.media.nowPlaying != nil)
        #expect(s.pages == [.timer, .music])
        #expect(s.nextDeadline == nil)
    }

    @Test func somethingAlreadyPausedAtLaunchDoesNotTakeTheWings() {
        let s = playing(track(playing: false))
        #expect(s.layout == .dormant)
        #expect(s.pages == [.timer, .music])
    }

    @Test func aGapBetweenTracksDoesNotFlicker() {
        var s = playing()
        s.reduce(.nowPlaying(nil), at: secs(10))
        #expect(s.layout == .music)
        #expect(s.nextDeadline == secs(10).advanced(by: Media.vanishGrace))
        s.reduce(.nowPlaying(track("Next", elapsed: 0, at: 11)), at: secs(11))
        #expect(s.media.nowPlaying?.track.title == "Next")
        s.reduce(.tick, at: secs(20))
        #expect(s.layout == .music)
    }

    @Test func musicThatStopsReportingLeavesAfterTheGrace() {
        var s = playing()
        s.reduce(.pointerDown(onNotch), at: secs(1))
        s.reduce(.nowPlaying(nil), at: secs(10))
        #expect(s.page == .music)
        s.reduce(.tick, at: secs(10).advanced(by: Media.vanishGrace))
        #expect(s.media.nowPlaying == nil)
        #expect(s.page == .timer)
        #expect(s.pages == [.timer])
        s.reduce(.pointerDown(farAway), at: secs(13))
        #expect(s.layout == .dormant)
    }

    @Test func theMusicPageNeedsSomethingPlaying() {
        var s = launched()
        s.reduce(.pointerDown(onNotch), at: t0)
        s.reduce(.showPage(.music), at: secs(1))
        #expect(s.page == .timer)
        s.reduce(.nowPlaying(track()), at: secs(2))
        s.reduce(.showPage(.music), at: secs(3))
        #expect(s.page == .music)
    }

    @Test func aTimerTakesTheWingsAndOpensToItsPage() {
        var s = playing()
        s.reduce(.run(TimerDuration(seconds: 600)!, .focus(.fifty)), at: secs(1))
        #expect(s.layout == .glance)
        s.reduce(.pointerDown(onNotch), at: secs(2))
        #expect(s.page == .timer)
        #expect(s.pages == [.timer, .music])
        s.reduce(.showPage(.music), at: secs(3))
        #expect(s.page == .music)
        s.reduce(.timer(.reset), at: secs(4))
        s.reduce(.pointerDown(farAway), at: secs(5))
        #expect(s.layout == .music)
    }

    @Test func theCanvasDoesNotGrow() {
        let withoutMusic = NotchLayout.allCases.filter { $0 != .music }
            .map(geometry.activeRect(for:)).reduce(CGRect.null) { $0.union($1) }
        #expect(geometry.canvas == withoutMusic)
        #expect(geometry.size(for: .music) == geometry.size(for: .glance))
    }

    @Test(arguments: [
        (Timer.idle, Music.none, Agents.none, nil as Expected?),
        (.idle, .playing, .none, .music),
        (.idle, .pausedRecently, .none, .music),
        (.idle, .pausedLongAgo, .working, .agentsBusy),
        (.idle, .playing, .working, .music),
        (.idle, .playing, .attention, .agentAttention),
        (.running, .playing, .none, .timer),
        (.paused, .playing, .working, .timer),
        (.doneUnseen, .playing, .none, .timerDone),
        (.doneSeen, .playing, .none, .music),
    ])
    func wingPriority(timer: Timer, music: Music, agents: Agents, expected: Expected?) {
        var s = launched()
        let minute = TimerDuration(seconds: 60)!, hour = TimerDuration(seconds: 3600)!
        switch timer {
        case .idle: break
        case .running: s.reduce(.run(hour, .focus(.fifty)), at: t0)
        case .paused:
            s.reduce(.run(hour, .focus(.fifty)), at: t0)
            s.reduce(.timer(.pause), at: secs(1))
        case .doneUnseen:
            s.reduce(.run(minute, .focus(.fifty)), at: t0)
            s.reduce(.tick, at: secs(60))
        case .doneSeen:
            s.reduce(.run(minute, .focus(.fifty)), at: t0)
            s.reduce(.tick, at: secs(60))
            s.reduce(.pointerDown(onNotch), at: secs(61))
            s.reduce(.pointerDown(farAway), at: secs(62))
        }
        switch music {
        case .none: break
        case .playing: s.reduce(.nowPlaying(track(at: 63)), at: secs(63))
        case .pausedRecently:
            s.reduce(.nowPlaying(track(at: 63)), at: secs(63))
            s.reduce(.nowPlaying(track(playing: false)), at: secs(64))
        case .pausedLongAgo:
            s.reduce(.nowPlaying(track(at: 63)), at: secs(63))
            s.reduce(.nowPlaying(track(playing: false)), at: secs(64))
            s.reduce(.tick, at: secs(70))
        }
        let wall = wall0 + 70
        func agent(_ status: AgentStatus) -> AgentSession {
            let r = AgentRecord(tool: .claude, session: "a", cwd: "/src/x", status: status, toolName: nil,
                                since: wall, updated: wall, ended: false, pid: 1, pidStart: 1, host: nil)
            return AgentSession(record: r, liveness: .alive, wallNow: wall, now: secs(70))
        }
        switch agents {
        case .none: break
        case .working: s.reduce(.agents([agent(.working)]), at: secs(70))
        case .attention: s.reduce(.agents([agent(.question)]), at: secs(70))
        }
        #expect(s.wings.map(Expected.init) == expected)
        #expect((s.agentBadge != nil) == ([.timer, .timerDone, .music].contains(expected) && agents == .working))
    }

    enum Timer: Sendable { case idle, running, paused, doneUnseen, doneSeen }
    enum Music: Sendable { case none, playing, pausedRecently, pausedLongAgo }
    enum Agents: Sendable { case none, working, attention }
    enum Expected: Sendable {
        case timerDone, agentAttention, timer, music, agentsBusy
        init(_ w: WingContent) {
            switch w {
            case .timerDone: self = .timerDone
            case .agentAttention: self = .agentAttention
            case .timer: self = .timer
            case .music: self = .music
            case .agentsBusy: self = .agentsBusy
            }
        }
    }
}

@Suite struct MediaCommands {
    @Test func aRefreshThatPredictsTheSamePositionChangesNothing() {
        let s = playing(track(elapsed: 30, at: 0))
        var refreshed = s
        refreshed.reduce(.nowPlaying(track(elapsed: 40.4, at: 10)), at: secs(10))
        #expect(refreshed == s)
        refreshed.reduce(.nowPlaying(track(elapsed: 40.6, at: 10)), at: secs(10))
        #expect(refreshed != s)
        #expect(abs((refreshed.media.nowPlaying?.position(at: secs(10)) ?? .zero).seconds - 40.6) < 0.001)
    }

    @Test func toggleIsResolvedAndShownAtOnce() {
        var s = playing()
        s.reduce(.media(.togglePlayPause), at: secs(10))
        #expect(s.media.request == MediaRequest(id: 1, command: .pause))
        #expect(s.media.nowPlaying?.isPlaying == false)
        #expect(s.media.nowPlaying?.position(at: secs(99)) == .seconds(40))
        s.reduce(.media(.togglePlayPause), at: secs(11))
        #expect(s.media.request == MediaRequest(id: 2, command: .play))
        #expect(s.media.nowPlaying?.isPlaying == true)
    }

    @Test func aStaleReportDoesNotUndoAClickUntilTheTimeout() {
        var s = playing()
        s.reduce(.media(.togglePlayPause), at: secs(10))
        s.reduce(.nowPlaying(track(elapsed: 40.2, at: 10.2)), at: secs(10.2))
        #expect(s.media.nowPlaying?.isPlaying == false)
        s.reduce(.tick, at: secs(10).advanced(by: Media.confirmTimeout))
        #expect(s.media.nowPlaying?.isPlaying == true)
    }

    @Test func aConfirmingReportEndsTheExpectation() {
        var s = playing()
        s.reduce(.media(.togglePlayPause), at: secs(10))
        s.reduce(.nowPlaying(track(playing: false, elapsed: 40.1)), at: secs(10.3))
        #expect(s.media.nowPlaying?.isPlaying == false)
        #expect(s.media.expected == nil)
        s.reduce(.tick, at: secs(20))
        #expect(s.media.nowPlaying?.isPlaying == false)
    }

    @Test func seekIsClampedAndKeepsPlaying() {
        var s = playing()
        s.reduce(.media(.seek(to: .seconds(500))), at: secs(1))
        #expect(s.media.request?.command == .seek(to: .seconds(200)))
        s.reduce(.media(.seek(to: .seconds(60))), at: secs(2))
        #expect(s.media.request == MediaRequest(id: 2, command: .seek(to: .seconds(60))))
        #expect(s.media.nowPlaying?.position(at: secs(3)) == .seconds(61))
    }

    @Test func commandsThatCannotApplyAreDroppedWithoutAnID() {
        var s = launched()
        s.reduce(.media(.next), at: t0)
        s.reduce(.media(.togglePlayPause), at: t0)
        s.reduce(.media(.setVolume(0.5)), at: t0)
        #expect(s.media.request == nil)
        s.reduce(.nowPlaying(track(length: nil)), at: t0)
        s.reduce(.media(.seek(to: .seconds(5))), at: secs(1))
        #expect(s.media.request == nil)
        s.reduce(.media(.next), at: secs(2))
        s.reduce(.media(.previous), at: secs(3))
        s.reduce(.media(.stop), at: secs(4))
        #expect(s.media.request == MediaRequest(id: 3, command: .stop))
        #expect(s.media.nowPlaying?.isPlaying == false)
    }

    @Test func volumeIsTheMacsAndSettingItUnmutes() {
        var s = launched()
        s.reduce(.outputVolume(OutputVolume(level: 0.8, isMuted: true)), at: t0)
        s.reduce(.media(.setVolume(1.4)), at: secs(1))
        #expect(s.media.volume == OutputVolume(level: 1, isMuted: false))
        #expect(s.media.request == MediaRequest(id: 1, command: .setVolume(1)))
        s.reduce(.outputVolume(nil), at: secs(2))
        s.reduce(.media(.setVolume(0.2)), at: secs(3))
        #expect(s.media.request?.id == 1)
    }

    @Test func aNewTrackDropsTheOldExpectation() {
        var s = playing()
        s.reduce(.media(.togglePlayPause), at: secs(10))
        s.reduce(.nowPlaying(track("Next", elapsed: 0, at: 10.5)), at: secs(10.5))
        #expect(s.media.nowPlaying?.track.title == "Next")
        #expect(s.media.nowPlaying?.isPlaying == true)
    }
}

@Suite struct AdapterLines {
    /// The shape of a line from `stream --micros` in the VM, with the fixture player playing.
    private let full = #"""
    {"type":"data","diff":false,"payload":{"playbackRate":1,"timestampEpochMicros":1795478401922891,"album":"VM","mediaType":"kMRMediaRemoteNowPlayingInfoTypeAudio","elapsedTimeMicros":30000000,"playing":true,"supportedCommands":[{"id":0,"name":"Play","enabled":true}],"bundleIdentifier":"app.notched.fixture-player","processIdentifier":812,"durationMicros":240000000,"title":"Fixture Track 1","artist":"Notched Test"}}
    """#

    @Test func aFullLineIsTheWholeState() throws {
        var stream = AdapterStream()
        let p = try #require(try stream.feed(full))
        #expect(p.bundleID == "app.notched.fixture-player")
        #expect(p.playing && p.title == "Fixture Track 1" && p.artist == "Notched Test" && p.album == "VM")
        #expect(p.duration == .seconds(240))
        #expect(p.elapsed == .seconds(30))
        #expect(abs((p.timestamp ?? 0) - 1_795_478_401.922891) < 1e-6)
        #expect(p.rate == 1)
        #expect(p.artworkBase64 == nil)
    }

    @Test func aDiffUpdatesAndANullRemoves() throws {
        var stream = AdapterStream()
        _ = try stream.feed(full)
        let p = try #require(try stream.feed(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0,"album":null}}"#))
        #expect(!p.playing && p.rate == 0 && p.album == nil)
        #expect(p.title == "Fixture Track 1" && p.duration == .seconds(240))
    }

    @Test func anEmptyFullLineMeansNothingPlays() throws {
        var stream = AdapterStream()
        _ = try stream.feed(full)
        #expect(try stream.feed(#"{"type":"data","diff":false,"payload":{}}"#) == nil)
        let p = try stream.feed(#"{"type":"data","diff":true,"payload":{"title":"Only a title"}}"#)
        #expect(p == nil)
    }

    @Test func aBrokenLineThrowsAndKeepsTheState() throws {
        var stream = AdapterStream()
        let before = try stream.feed(full)
        #expect(throws: AdapterStreamError.notJSON) { try stream.feed(String(full.dropLast(20))) }
        #expect(throws: AdapterStreamError.unexpectedType("error")) {
            try stream.feed(#"{"type":"error","diff":false,"payload":{}}"#)
        }
        #expect(try stream.feed(#"{"type":"data","diff":true,"payload":{}}"#) == before)
    }

    @Test func aBrowserTabIsNamedByItsApp() throws {
        var stream = AdapterStream()
        let p = try stream.feed(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","playing":true,"title":"Video"}}"#)
        #expect(p?.bundleID == "com.apple.Safari")
        #expect(p?.duration == nil && p?.elapsed == nil)
    }

    @Test func aPayloadMovesOntoTheAppsClock() throws {
        var stream = AdapterStream()
        let p = try #require(try stream.feed(full))
        let wallNow = 1_795_478_401.922891 + 2
        let n = NowPlaying(payload: p, playerName: "Fixture", artwork: nil, wallNow: wallNow, now: t0)
        #expect(n.player == Player(bundleID: "app.notched.fixture-player", name: "Fixture"))
        #expect(abs((n.position(at: t0) - .seconds(32)).seconds) < 0.001)

        let paused = try #require(try stream.feed(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#))
        let held = NowPlaying(payload: paused, playerName: "Fixture", artwork: nil, wallNow: wallNow, now: t0)
        #expect(held.playback == .paused(at: .seconds(30)))

        let playingAtRateZero = try #require(try stream.feed(#"{"type":"data","diff":true,"payload":{"playing":true}}"#))
        let ticking = NowPlaying(payload: playingAtRateZero, playerName: "Fixture", artwork: nil, wallNow: wallNow, now: t0)
        #expect(ticking.position(at: secs(1)) > ticking.position(at: t0))
    }
}

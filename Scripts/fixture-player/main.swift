// A silent stand-in media player for the Tart VM. It publishes now-playing info as a real player
// does, and appends every remote command it receives to the log file named by its first argument,
// one line each: "play", "pause", "toggle", "stop", "next", "previous", "seek <seconds>".
// Scripts/vm-selftest.sh builds it with build.sh and runs it in the VM only, never on the host.
import AppKit
import MediaPlayer

@MainActor
final class Player {
    private let log: URL
    private var track = 1
    private var playing = true
    private var elapsed: TimeInterval = 30
    private var anchor = Date()
    private let duration: TimeInterval = 240

    init(log: URL) {
        self.log = log
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [unowned self] _ in handle("play") { self.setPlaying(true) } }
        center.pauseCommand.addTarget { [unowned self] _ in handle("pause") { self.setPlaying(false) } }
        center.togglePlayPauseCommand.addTarget { [unowned self] _ in handle("toggle") { self.setPlaying(!self.playing) } }
        center.stopCommand.addTarget { [unowned self] _ in handle("stop") { self.setPlaying(false) } }
        center.nextTrackCommand.addTarget { [unowned self] _ in handle("next") { self.skip(1) } }
        center.previousTrackCommand.addTarget { [unowned self] _ in handle("previous") { self.skip(-1) } }
        center.changePlaybackPositionCommand.addTarget { [unowned self] event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? -1
            return handle(String(format: "seek %.1f", seconds)) { self.seek(to: seconds) }
        }
        publish()
    }

    private func handle(_ line: String, _ change: @escaping () -> Void) -> MPRemoteCommandHandlerStatus {
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        change()
        return .success
    }

    private var position: TimeInterval { playing ? elapsed + Date().timeIntervalSince(anchor) : elapsed }

    private func setPlaying(_ on: Bool) {
        elapsed = position
        anchor = Date()
        playing = on
        publish()
    }

    private func skip(_ by: Int) {
        track = max(1, track + by)
        elapsed = 0
        anchor = Date()
        publish()
    }

    private func seek(to seconds: TimeInterval) {
        elapsed = seconds
        anchor = Date()
        publish()
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Fixture Track \(track)",
            MPMediaItemPropertyArtist: "Notched Test",
            MPMediaItemPropertyAlbumTitle: "VM",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = playing ? .playing : .paused
    }
}

let arguments = CommandLine.arguments
let log = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory() + "fixture-player.log")
FileManager.default.createFile(atPath: log.path, contents: nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let player = MainActor.assumeIsolated { Player(log: log) }
app.run()

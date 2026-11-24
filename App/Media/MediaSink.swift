import NotchedCore

/// Carries out the domain's media requests: transport to the adapter, volume to CoreAudio. It acts
/// once per request id, so reconciling twice sends nothing twice. A test run has no adapter and no
/// volume control, so it only records what it would have sent.
@MainActor
final class MediaSink {
    private let source: AdapterSource?
    private let volume: SystemVolume?
    private var lastID = 0
    /// The last command acted on, and how many so far. A test run reads these instead of a player.
    private(set) var lastCommand: MediaCommand?
    private(set) var count = 0

    init(source: AdapterSource?, volume: SystemVolume?) {
        self.source = source
        self.volume = volume
    }

    func reflect(_ request: MediaRequest?) {
        guard let request, request.id > lastID else { return }
        lastID = request.id
        lastCommand = request.command
        count += 1
        if case .setVolume(let level) = request.command {
            volume?.set(level)
        } else {
            source?.send(request.command)
        }
    }
}

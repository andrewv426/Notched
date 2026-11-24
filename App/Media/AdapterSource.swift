import AppKit
import NotchedCore
import os

/// Reads what is playing from the vendored mediaremote-adapter and sends it transport commands.
///
/// macOS 15.4 and later answer MediaRemote only for Apple's own binaries, so the adapter runs as a
/// framework loaded into `/usr/bin/perl` (see Vendor/MediaRemoteAdapter). One long-lived
/// `stream` process pushes JSON lines; each command is a short-lived `send` or `seek` process. This
/// class parses at the boundary and decides nothing: it turns lines into `.nowPlaying` values.
@MainActor
final class AdapterSource {
    private let script: URL
    private let framework: URL
    private let artwork: ArtworkCache
    private let deliver: @MainActor (NowPlaying?) -> Void
    private var stream: Process?
    private var reader: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var quickExits = 0
    private var commands: [Process] = []
    private var lastArtwork: (base64: String, key: ArtworkKey?)?
    private var names: [String: String] = [:]
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private static let log = Logger(subsystem: "app.notched.Notched", category: "media")

    /// Nil when the app bundle lacks the adapter, which only a broken build does.
    init?(bundle: Bundle, artwork: ArtworkCache, deliver: @escaping @MainActor (NowPlaying?) -> Void) {
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: frameworks.path) else {
            Self.log.error("the media adapter is missing from the app bundle")
            return nil
        }
        self.script = script
        framework = frameworks
        self.artwork = artwork
        self.deliver = deliver
    }

    func start() {
        guard stream == nil, restart == nil else { return }
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path, framework.path, "stream", "--micros", "--debounce=150"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Self.log.error("cannot start the media adapter: \(error.localizedDescription, privacy: .public)")
            quickExits += 1
            scheduleRestart()
            return
        }
        stream = process
        let started = ContinuousClock.now
        let lines = output.fileHandleForReading.bytes.lines
        reader = Task.detached { [weak self] in
            var parser = AdapterStream()
            do {
                for try await line in lines {
                    let payload: AdapterPayload?
                    do { payload = try parser.feed(line) } catch { continue }
                    await self?.receive(payload)
                }
            } catch {}
            await self?.ended(ranFor: started.duration(to: .now))
        }
    }

    func stop() {
        restart?.cancel()
        restart = nil
        reader?.cancel()
        reader = nil
        stream?.terminate()
        stream = nil
    }

    func send(_ command: MediaCommand) {
        let arguments: [String]
        switch command {
        case .play: arguments = ["send", "0"]
        case .pause: arguments = ["send", "1"]
        case .stop: arguments = ["send", "3"]
        case .next: arguments = ["send", "4"]
        case .previous: arguments = ["send", "5"]
        case .seek(let position):
            let c = position.components
            arguments = ["seek", String(c.seconds * 1_000_000 + c.attoseconds / 1_000_000_000_000)]
        case .setVolume: return
        }
        commands.removeAll { !$0.isRunning }
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path, framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            commands.append(process)
        } catch {
            Self.log.error("cannot send \(arguments[0], privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receive(_ payload: AdapterPayload?) {
        guard let payload else { return deliver(nil) }
        deliver(NowPlaying(payload: payload, playerName: name(of: payload.bundleID),
                           artwork: artworkKey(payload.artworkBase64),
                           wallNow: Date().timeIntervalSince1970, now: .now))
    }

    /// The stream ended: the adapter exited or was killed. Nothing is known to play until it is back.
    private func ended(ranFor: Duration) {
        guard stream != nil else { return }
        stream = nil
        reader = nil
        deliver(nil)
        quickExits = ranFor < .seconds(60) ? quickExits + 1 : 0
        Self.log.error("the media adapter exited (\(self.quickExits) quick exit(s) in a row)")
        scheduleRestart()
    }

    /// Backs off 1, 2, 4 … up to 300 s while the adapter keeps exiting quickly.
    private func scheduleRestart() {
        let delay = Duration.seconds(min(300, 1 << min(quickExits, 9)))
        restart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restart = nil
            self?.start()
        }
    }

    /// Decodes and caches artwork once per change; a refresh with the same bytes reuses the key.
    private func artworkKey(_ base64: String?) -> ArtworkKey? {
        guard let base64 else { return nil }
        if let last = lastArtwork, last.base64 == base64 { return last.key }
        let key = Data(base64Encoded: base64).flatMap(artwork.insert)
        lastArtwork = (base64, key)
        return key
    }

    private func name(of bundleID: String) -> String {
        if let known = names[bundleID] { return known }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        names[bundleID] = name
        return name
    }
}

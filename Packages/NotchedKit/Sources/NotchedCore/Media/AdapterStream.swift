import Foundation

/// What `mediaremote-adapter.pl … stream --micros` says is playing, after merging diffs.
public struct AdapterPayload: Equatable, Sendable {
    /// The app the user knows: the parent app for a helper process (a browser's media process).
    public let bundleID: String
    public let playing: Bool
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: Duration?
    /// The position at `timestamp`.
    public let elapsed: Duration?
    /// Wall-clock seconds since 1970.
    public let timestamp: Double?
    public let rate: Double?
    /// Base64, as the adapter sends it. The app decodes it once per change.
    public let artworkBase64: String?
}

public enum AdapterStreamError: Error, Equatable {
    case notJSON
    case unexpectedType(String)
}

/// Turns the adapter's stream, one JSON line at a time, into the current payload. A line is
/// `{"type":"data","diff":Bool,"payload":{…}}`: a full payload replaces the state, a diff updates
/// it, and a null value in a diff removes that key. An empty full payload means nothing is playing.
public struct AdapterStream: Sendable {
    private var fields: [String: Field] = [:]

    public init() {}

    /// Applies one line and returns what is playing after it, or nil when nothing is. A line that
    /// does not parse throws and leaves the state as it was.
    public mutating func feed(_ line: some StringProtocol) throws(AdapterStreamError) -> AdapterPayload? {
        let decoded: Line
        do { decoded = try JSONDecoder().decode(Line.self, from: Data(line.utf8)) } catch { throw .notJSON }
        guard decoded.type == "data" else { throw .unexpectedType(decoded.type) }
        if !decoded.diff { fields = [:] }
        for (key, value) in decoded.payload {
            fields[key] = value == .null ? nil : value
        }
        return payload
    }

    private var payload: AdapterPayload? {
        guard let id = string("parentApplicationBundleIdentifier") ?? string("bundleIdentifier"),
              case .bool(let playing) = fields["playing"],
              let title = string("title") else { return nil }
        return AdapterPayload(bundleID: id, playing: playing, title: title, artist: string("artist"),
                              album: string("album"), duration: micros("durationMicros"),
                              elapsed: micros("elapsedTimeMicros"),
                              timestamp: number("timestampEpochMicros").map { $0 / 1e6 },
                              rate: number("playbackRate"), artworkBase64: string("artworkData"))
    }

    private func string(_ key: String) -> String? {
        if case .string(let s) = fields[key], !s.isEmpty { return s }
        return nil
    }

    private func number(_ key: String) -> Double? {
        if case .number(let n) = fields[key], n.isFinite { return n }
        return nil
    }

    private func micros(_ key: String) -> Duration? {
        number(key).flatMap { $0 >= 0 ? .microseconds(Int64($0)) : nil }
    }

    private struct Line: Decodable {
        let type: String
        let diff: Bool
        let payload: [String: Field]
    }

    /// One payload value. Arrays and objects (`supportedCommands`) are not read.
    private enum Field: Decodable, Equatable, Sendable {
        case null, bool(Bool), number(Double), string(String), other

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .other }
        }
    }
}

extension NowPlaying {
    /// Converts a payload to the domain's clock: the adapter's wall-clock timestamp becomes an
    /// instant on this process's clock, so the domain keeps one clock. A timestamp in the future (a
    /// clock change) counts as now.
    public init(payload p: AdapterPayload, playerName: String, artwork: ArtworkKey?, wallNow: Double, now: Instant) {
        let elapsed = p.elapsed ?? .zero
        let instant = p.timestamp.map { now.advanced(by: .seconds(-max(0, wallNow - $0))) } ?? now
        let rate = p.rate.flatMap { $0 > 0 ? $0 : nil } ?? 1
        self.init(player: Player(bundleID: p.bundleID, name: playerName),
                  track: Track(title: p.title, artist: p.artist, album: p.album, duration: p.duration, artwork: artwork),
                  playback: p.playing ? .playing(elapsed: elapsed, instant: instant, rate: rate) : .paused(at: elapsed))
    }
}

import AppKit
import CryptoKit
import NotchedCore

/// Artwork images by key. State holds only the key, so comparing states never compares image
/// bytes; views look the image up here. Keeps the last few.
@MainActor
final class ArtworkCache {
    private var images: [ArtworkKey: NSImage] = [:]
    private var order: [ArtworkKey] = []
    private let capacity = 8

    /// Nil when the bytes are not an image.
    func insert(_ data: Data) -> ArtworkKey? {
        let key = ArtworkKey(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        if images[key] != nil { return key }
        guard let image = NSImage(data: data) else { return nil }
        images[key] = image
        order.append(key)
        if order.count > capacity { images[order.removeFirst()] = nil }
        return key
    }

    func image(for key: ArtworkKey?) -> NSImage? { key.flatMap { images[$0] } }
}

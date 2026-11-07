import AppKit
import QuickLookThumbnailing

/// Generates and caches Quick Look thumbnails.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    enum Side {
        static let list: CGFloat = 80
        static let grid: CGFloat = 320
    }

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [NSString: [(NSImage) -> Void]] = [:]

    private init() {
        cache.countLimit = 3000
    }

    func cachedThumbnail(for item: Screenshot, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, side))
    }

    /// Calls `completion` on the main queue. Calls it synchronously when the thumbnail is cached.
    func thumbnail(for item: Screenshot, side: CGFloat, scale: CGFloat,
                   completion: @escaping (NSImage) -> Void) {
        let key = key(item, side)
        if let image = cache.object(forKey: key) {
            completion(image)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        let url = item.url
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                let result = image ?? NSWorkspace.shared.icon(forFile: url.path)
                self.cache.setObject(result, forKey: key)
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(result) }
            }
        }
    }

    private func key(_ item: Screenshot, _ side: CGFloat) -> NSString {
        "\(item.url.path)|\(item.modificationDate.timeIntervalSinceReferenceDate)|\(Int(side))" as NSString
    }
}

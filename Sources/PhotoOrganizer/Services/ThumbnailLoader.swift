import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PhotoOrganizerCore
import UniformTypeIdentifiers

/// Generates and caches downsampled images.
///
/// - Uses the preview embedded in RAW/JPEG files when it is large enough (fast), and decodes the
///   full image only when it isn't.
/// - Grid-sized thumbnails are also cached on disk (in ~/Library/Caches), keyed by path,
///   modification date and size, so revisiting a folder is instant even after relaunch.
final class ThumbnailLoader: @unchecked Sendable {  // NSCache and FileManager are thread-safe
    static let shared = ThumbnailLoader()

    /// Images at or below this size are persisted to disk.
    static let maxPersistedPixelSize = 1024
    static let diskCacheLimit: Int64 = 2 * 1024 * 1024 * 1024

    private let memory = NSCache<NSString, CGImage>()
    let diskFolder: URL

    private init() {
        memory.totalCostLimit = 768 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskFolder = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PhotoOrganizer")
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskFolder, withIntermediateDirectories: true)
        Task.detached(priority: .background) { [self] in self.prune(to: Self.diskCacheLimit) }
    }

    func image(for url: URL, modified: Date, maxPixelSize: Int) async -> CGImage? {
        let key = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)|\(maxPixelSize)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let persist = maxPixelSize <= Self.maxPersistedPixelSize
        let diskURL = diskFolder.appendingPathComponent(Self.hash(key)).appendingPathExtension("thumb")
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            if persist, let cached = Self.load(diskURL) { return cached }
            let image = Self.makeImage(url: url, maxPixelSize: maxPixelSize)
            if persist, let image { Self.store(image, at: diskURL) }
            return image
        }.value
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// The image at its full pixel size (used for 100% zoom). Not persisted.
    func fullImage(for url: URL, modified: Date) async -> CGImage? {
        let size = await Task.detached(priority: .userInitiated) { MetadataReader.pixelSize(of: url) }.value
        let longest = size.map { max($0.width, $0.height) } ?? 8192
        return await image(for: url, modified: modified, maxPixelSize: longest)
    }

    // MARK: - Disk cache

    func diskUsage() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    func clearDiskCache() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
        memory.removeAllObjects()
    }

    /// Deletes the least recently created entries until the cache is below 80% of `limit`.
    private func prune(to limit: Int64) {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        all.sort { $0.date < $1.date }
        for entry in all {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total < limit * 8 / 10 { break }
        }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: diskFolder, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.creationDate ?? .distantPast)
        }
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func store(_ image: CGImage, at url: URL) {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Decoding

    private static func makeImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        func thumbnail(fromFullImage: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
                fromFullImage ? kCGImageSourceCreateThumbnailFromImageAlways
                              : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if let embedded = thumbnail(fromFullImage: false), max(embedded.width, embedded.height) >= maxPixelSize / 2 {
            return embedded
        }
        return thumbnail(fromFullImage: true)
    }
}

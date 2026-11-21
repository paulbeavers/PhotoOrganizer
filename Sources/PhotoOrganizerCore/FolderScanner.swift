import Foundation
import UniformTypeIdentifiers

/// An image file in a browsed folder.
public struct PhotoFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let fileSize: Int
    public let modified: Date
    public let contentType: UTType?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, fileSize: Int, modified: Date, contentType: UTType?) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
        self.contentType = contentType
    }
}

public enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
    ]

    /// Image files (JPEG, HEIC, TIFF, PSD, PNG, camera RAW, ...) inside `folder`, sorted by name.
    /// With `recursive`, includes every subfolder (skipping hidden folders and packages).
    public static func photos(in folder: URL, recursive: Bool = false,
                              isCancelled: () -> Bool = { false }) throws -> [PhotoFile] {
        let urls: [URL]
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
            }
            let hidden = CompanionFileType.folderNames
            var found: [URL] = []
            for case let url as URL in enumerator {
                if isCancelled() { return [] }
                if hidden.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                found.append(url)
            }
            urls = found
        } else {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        var seen = Set<URL>()
        return photoFiles(urls)
            .filter { seen.insert($0.url).inserted }   // a photo and a link to it: once
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `PhotoFile`s for the given URLs that exist and are images (order preserved). A symbolic link
    /// (e.g. in a day's `Picked` folder) stands for the photo it points to.
    public static func photoFiles(_ urls: [URL]) -> [PhotoFile] {
        urls.compactMap { link -> PhotoFile? in
            let url = resolvingLink(link)
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true,
                  isPhoto(url: url, type: values.contentType) else { return nil }
            return PhotoFile(url: url,
                             fileSize: values.fileSize ?? 0,
                             modified: values.contentModificationDate ?? .distantPast,
                             contentType: values.contentType)
        }
    }

    /// The target of a symbolic link (relative targets resolved against the link's folder, keeping
    /// the path's spelling); any other URL unchanged.
    public static func resolvingLink(_ url: URL) -> URL {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
        // An absolute URL (not one relative to the link's folder: URLs with different bases never
        // compare equal, and the photo would be listed twice).
        let path = target.hasPrefix("/") ? target : url.deletingLastPathComponent().path + "/" + target
        return URL(fileURLWithPath: path).standardized   // resolves "..", keeps the spelling (no /private stripping)
    }

    /// Visible, non-package subfolders of `folder`, sorted by name.
    public static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let hidden = CompanionFileType.folderNames
        return items.filter { url in
            guard !hidden.contains(url.lastPathComponent) else { return false }  // e.g. NX Studio's NKSC_PARAM
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func isPhoto(url: URL, type: UTType?) -> Bool {
        guard url.pathExtension.lowercased() != "xmp", let type else { return false }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }
}

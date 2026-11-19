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
    public static func photos(in folder: URL, recursive: Bool = false) throws -> [PhotoFile] {
        let urls: [URL]
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        return photoFiles(urls)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `PhotoFile`s for the given URLs that exist and are images (order preserved).
    public static func photoFiles(_ urls: [URL]) -> [PhotoFile] {
        urls.compactMap { url -> PhotoFile? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true,
                  isPhoto(url: url, type: values.contentType) else { return nil }
            return PhotoFile(url: url,
                             fileSize: values.fileSize ?? 0,
                             modified: values.contentModificationDate ?? .distantPast,
                             contentType: values.contentType)
        }
    }

    /// Visible, non-package subfolders of `folder`, sorted by name.
    public static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
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

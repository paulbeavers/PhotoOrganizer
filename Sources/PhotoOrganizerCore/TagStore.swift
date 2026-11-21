import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TagStoreError: Error, LocalizedError {
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .serializationFailed: "The XMP sidecar could not be serialized."
        }
    }
}

/// Locates and reads XMP sidecar files. Every photo has its own:
///
/// - RAW files use the Adobe convention, `DSC_0001.NEF` → `DSC_0001.xmp`, which Camera Raw,
///   Photoshop, Bridge and Lightroom read.
/// - Everything else (JPEG, TIFF, PSD, HEIC…) uses the full file name, `DSC_0001.JPG` →
///   `DSC_0001.JPG.xmp` (as darktable and digiKam do). Adobe apps never read a separate sidecar for
///   these formats, and this way the JPEG of a RAW+JPEG pair doesn't share the RAW's tags.
///
/// Before v0.3.1 every file used `<base>.xmp`; a non-RAW photo still reads that (see `legacyURL`).
public enum Sidecar {
    public static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    /// Where this photo's tags are written.
    public static func url(for imageURL: URL) -> URL {
        isRaw(imageURL) ? sharedURL(for: imageURL) : imageURL.appendingPathExtension("xmp")
    }

    /// `<folder>/<base name>.xmp`: a RAW file's sidecar.
    public static func sharedURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// A non-RAW photo's `<base>.xmp` from before per-file sidecars, if it has one: only when no RAW
    /// file shares the base name (otherwise that sidecar is the RAW's).
    public static func legacyURL(for imageURL: URL) -> URL? {
        guard !isRaw(imageURL) else { return nil }
        let shared = sharedURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: shared.path) else { return nil }
        let base = imageURL.deletingPathExtension().lastPathComponent
        let rawSibling = FileOperations.photos(in: imageURL.deletingLastPathComponent(), baseName: base).contains(where: isRaw)
        return rawSibling ? nil : shared
    }

    /// The sidecar to read tags from: the photo's own, else a legacy one.
    public static func existingURL(for imageURL: URL) -> URL? {
        let own = url(for: imageURL)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        return legacyURL(for: imageURL)
    }

    public static func readMetadata(at sidecarURL: URL) -> CGImageMetadata? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return CGImageMetadataCreateFromXMPData(data as CFData)
    }
}

/// Reads and writes `PhotoTags`.
///
/// - Reading: the XMP sidecar wins if present; otherwise XMP embedded in the image is used
///   (e.g. a rating set in-camera or by another app).
/// - Writing: always goes to the sidecar, never to the original image. Existing sidecar content
///   (Camera Raw develop settings, other apps' fields) is preserved; only fields whose values
///   actually change are touched.
public struct TagStore: Sendable {
    public init() {}

    public func tags(for imageURL: URL) -> PhotoTags {
        if let url = Sidecar.existingURL(for: imageURL), let sidecar = Sidecar.readMetadata(at: url) {
            return XMPTags.read(from: sidecar)
        }
        return embeddedTags(for: imageURL) ?? .empty
    }

    /// Applies `change` to the photo's tags and persists the result. Returns the new tags.
    @discardableResult
    public func update(_ imageURL: URL, _ change: (inout PhotoTags) -> Void) throws -> PhotoTags {
        let sidecarURL = Sidecar.url(for: imageURL)
        let metadata: CGMutableImageMetadata
        let current: PhotoTags
        let baseline: PhotoTags   // what the sidecar itself currently contains

        if let existing = Sidecar.readMetadata(at: sidecarURL)
            ?? Sidecar.legacyURL(for: imageURL).flatMap(Sidecar.readMetadata) {
            // (A legacy `<base>.xmp` is copied whole into the photo's own new sidecar.)
            metadata = CGImageMetadataCreateMutableCopy(existing) ?? CGImageMetadataCreateMutable()
            current = XMPTags.read(from: existing)
            baseline = current
        } else {
            // New sidecar: seed it with any embedded tags so they carry over.
            metadata = CGImageMetadataCreateMutable()
            current = embeddedTags(for: imageURL) ?? .empty
            baseline = .empty
        }

        var updated = current
        change(&updated)
        updated.normalize()
        guard updated != current else { return current }

        XMPTags.write(updated, changedFrom: baseline, into: metadata)
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else {
            throw TagStoreError.serializationFailed
        }
        try data.write(to: sidecarURL, options: .atomic)
        return updated
    }

    private func embeddedTags(for imageURL: URL) -> PhotoTags? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, options),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return XMPTags.read(from: metadata)
    }
}

/// Mapping between `PhotoTags` and the standard XMP properties used by Adobe apps.
enum XMPTags {
    static var lightroomNamespace: CFString { "http://ns.adobe.com/lightroom/1.0/" as CFString }
    static var appNamespace: CFString { "http://ns.photoorganizer.app/1.0/" as CFString }

    /// How an IPTC field is represented in XMP.
    private enum Shape { case altText, text, orderedArray }

    private static func location(of field: IPTCField) -> (namespace: CFString, prefix: String, name: String, shape: Shape) {
        switch field {
        case .title: (kCGImageMetadataNamespaceDublinCore, "dc", "title", .altText)
        case .caption: (kCGImageMetadataNamespaceDublinCore, "dc", "description", .altText)
        case .copyright: (kCGImageMetadataNamespaceDublinCore, "dc", "rights", .altText)
        case .creator: (kCGImageMetadataNamespaceDublinCore, "dc", "creator", .orderedArray)
        case .headline: (kCGImageMetadataNamespacePhotoshop, "photoshop", "Headline", .text)
        case .city: (kCGImageMetadataNamespacePhotoshop, "photoshop", "City", .text)
        case .state: (kCGImageMetadataNamespacePhotoshop, "photoshop", "State", .text)
        case .country: (kCGImageMetadataNamespacePhotoshop, "photoshop", "Country", .text)
        case .location: (kCGImageMetadataNamespaceIPTCCore, "Iptc4xmpCore", "Location", .text)
        }
    }

    static func read(from metadata: CGImageMetadata) -> PhotoTags {
        var tags = PhotoTags()
        if let value = string(metadata, "xmp:Rating"), let rating = Double(value) {
            tags.rating = Int(rating)
        }
        tags.isPicked = string(metadata, "photoorganizer:Pick") == "1"
        if let value = string(metadata, "xmp:Label") {
            tags.label = ColorLabel(xmpValue: value)
        }

        let flat = strings(metadata, "dc:subject")
        let hierarchical = strings(metadata, "lr:hierarchicalSubject")
        if hierarchical.isEmpty {
            tags.keywords = flat
        } else {
            // Flat keywords that are just levels of a hierarchical keyword are redundant.
            let covered = Set(hierarchical.flatMap(Keyword.components).map { $0.lowercased() })
            tags.keywords = hierarchical + flat.filter { !covered.contains($0.lowercased()) }
        }

        for field in IPTCField.allCases {
            let loc = location(of: field)
            let path = "\(loc.prefix):\(loc.name)"
            switch loc.shape {
            case .altText: tags.fields[field] = string(metadata, path)
            case .text, .orderedArray: tags.fields[field] = strings(metadata, path).joined(separator: "; ")
            }
        }
        tags.normalize()
        return tags
    }

    static func write(_ new: PhotoTags, changedFrom old: PhotoTags, into metadata: CGMutableImageMetadata) {
        registerNamespaces(metadata)

        if new.rating != old.rating {
            if new.rating != 0 {
                setTag(metadata, kCGImageMetadataNamespaceXMPBasic, "xmp", "Rating", .string, String(new.rating) as CFString)
            } else {
                remove(metadata, "xmp:Rating")
            }
        }
        if new.isPicked != old.isPicked {
            if new.isPicked {
                setTag(metadata, appNamespace, "photoorganizer", "Pick", .string, "1" as CFString)
            } else {
                remove(metadata, "photoorganizer:Pick")
            }
        }
        if new.label != old.label {
            if let label = new.label {
                setTag(metadata, kCGImageMetadataNamespaceXMPBasic, "xmp", "Label", .string, label.rawValue as CFString)
            } else {
                remove(metadata, "xmp:Label")
            }
        }
        if new.keywords != old.keywords {
            if new.keywords.isEmpty {
                remove(metadata, "dc:subject")
            } else {
                setTag(metadata, kCGImageMetadataNamespaceDublinCore, "dc", "subject", .arrayUnordered,
                       Keyword.flattened(new.keywords) as CFArray)
            }
            if new.keywords.contains(where: { $0.contains(Keyword.separator) }) {
                setTag(metadata, lightroomNamespace, "lr", "hierarchicalSubject", .arrayUnordered, new.keywords as CFArray)
            } else {
                remove(metadata, "lr:hierarchicalSubject")
            }
        }
        for field in IPTCField.allCases where new.fields[field] != old.fields[field] {
            let loc = location(of: field)
            let path = "\(loc.prefix):\(loc.name)"
            remove(metadata, path)
            guard let value = new.fields[field] else { continue }
            switch loc.shape {
            case .altText:
                CGImageMetadataSetValueWithPath(metadata, nil, "\(path)[x-default]" as CFString, value as CFString)
            case .text:
                setTag(metadata, loc.namespace, loc.prefix, loc.name, .string, value as CFString)
            case .orderedArray:
                let items = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                setTag(metadata, loc.namespace, loc.prefix, loc.name, .arrayOrdered, items as CFArray)
            }
        }
    }

    private static func registerNamespaces(_ metadata: CGMutableImageMetadata) {
        let namespaces: [(CFString, String)] = [
            (kCGImageMetadataNamespaceXMPBasic, "xmp"),
            (kCGImageMetadataNamespaceDublinCore, "dc"),
            (kCGImageMetadataNamespacePhotoshop, "photoshop"),
            (kCGImageMetadataNamespaceIPTCCore, "Iptc4xmpCore"),
            (lightroomNamespace, "lr"),
            (appNamespace, "photoorganizer"),
        ]
        for (namespace, prefix) in namespaces {
            CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix as CFString, nil)
        }
    }

    private static func setTag(_ metadata: CGMutableImageMetadata, _ namespace: CFString, _ prefix: String,
                               _ name: String, _ type: CGImageMetadataType, _ value: CFTypeRef) {
        guard let tag = CGImageMetadataTagCreate(namespace, prefix as CFString, name as CFString, type, value) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
    }

    private static func remove(_ metadata: CGMutableImageMetadata, _ path: String) {
        CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
    }

    private static func string(_ metadata: CGImageMetadata, _ path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    private static func strings(_ metadata: CGImageMetadata, _ path: String) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return [] }
        return strings(fromTag: tag)
    }

    static func strings(fromTag tag: CGImageMetadataTag) -> [String] {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        return strings(fromValue: value)
    }

    static func strings(fromValue value: CFTypeRef) -> [String] {
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return [value as! String]
        }
        if typeID == CGImageMetadataTagGetTypeID() {
            return strings(fromTag: value as! CGImageMetadataTag)
        }
        if typeID == CFArrayGetTypeID() {
            return (value as! [AnyObject]).flatMap { strings(fromValue: $0) }
        }
        return []
    }
}

/// Which other apps have edited a photo through their own settings files (edits this app can't
/// show in previews): Camera Raw / Lightroom settings in the XMP sidecar, and NX Studio,
/// RawTherapee and DxO PhotoLab settings files.
public enum EditDetector {
    public static let cameraRaw = "Camera Raw"

    /// Editor names, e.g. ["Camera Raw", "NX Studio"]; empty when nothing edited the photo.
    public static func editors(of photo: URL) -> [String] {
        var editors: [String] = []
        if let sidecar = Sidecar.existingURL(for: photo), hasCameraRawSettings(sidecar) {
            editors.append(cameraRaw)
        }
        for companion in CompanionFileType.existing(for: photo) where companion.type != .xmpSidecar {
            editors.append(companion.type.editor)
        }
        return editors
    }

    /// Camera Raw marks a sidecar it has adjusted with `crs:HasSettings="True"` (attribute or
    /// element form).
    static func hasCameraRawSettings(_ sidecar: URL) -> Bool {
        guard let data = try? Data(contentsOf: sidecar), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(#"crs:HasSettings="True""#) || text.contains("<crs:HasSettings>True</crs:HasSettings>")
    }
}

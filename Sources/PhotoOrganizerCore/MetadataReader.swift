import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MetadataEntry: Identifiable, Hashable, Sendable {
    public let key: String
    public let value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct MetadataSection: Identifiable, Hashable, Sendable {
    public let title: String
    public let entries: [MetadataEntry]
    public var id: String { title }
}

public struct PhotoMetadata: Sendable {
    /// Curated, human-friendly fields (camera, lens, exposure, ...).
    public let summary: [MetadataEntry]
    /// Every property ImageIO exposes, grouped by dictionary (EXIF, TIFF, GPS, IPTC, maker notes,
    /// embedded XMP, sidecar XMP).
    public let sections: [MetadataSection]
}

public enum MetadataReader {
    public static func read(_ url: URL) -> PhotoMetadata {
        var summary: [MetadataEntry] = []
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { summary.append(MetadataEntry(key: key, value: value)) }
        }

        let file = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        add("Name", url.lastPathComponent)
        add("Kind", file?.contentType?.localizedDescription)
        add("Size", file?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) })
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            add("Dimensions", "\(w) × \(h)")
        }
        add("Date Taken", exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
        add("Camera", (tiff[kCGImagePropertyTIFFModel as String] ?? tiff[kCGImagePropertyTIFFMake as String]) as? String)
        add("Lens", (exif[kCGImagePropertyExifLensModel as String] ?? aux[kCGImagePropertyExifAuxLensModel as String]) as? String)
        add("Focal Length", number(exif[kCGImagePropertyExifFocalLength as String]).map { "\(format($0)) mm" })
        add("Aperture", number(exif[kCGImagePropertyExifFNumber as String]).map { "f/\(format($0))" })
        add("Shutter", number(exif[kCGImagePropertyExifExposureTime as String]).map(formatShutter))
        add("ISO", (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first.map { "\($0)" })
        add("Exposure Comp.", number(exif[kCGImagePropertyExifExposureBiasValue as String]).map { "\(format($0)) EV" })
        add("Location", formatGPS(gps))
        add("Created", file?.creationDate?.formatted(date: .abbreviated, time: .standard))
        add("Modified", file?.contentModificationDate?.formatted(date: .abbreviated, time: .standard))
        add("Path", url.path)

        var sections: [MetadataSection] = []
        let general = props.filter { !($0.value is [String: Any]) }
        if !general.isEmpty { sections.append(section("Image", entries(general))) }
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            guard let dictionary = value as? [String: Any] else { continue }
            sections.append(section(sectionTitle(key), entries(dictionary)))
        }
        if let source, let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            sections.append(section("XMP (Embedded)", xmpEntries(xmp)))
        }
        if let sidecar = Sidecar.readMetadata(at: Sidecar.url(for: url)) {
            sections.append(section("XMP (Sidecar)", xmpEntries(sidecar)))
        }

        return PhotoMetadata(summary: summary, sections: sections.filter { !$0.entries.isEmpty })
    }

    // MARK: - Individual values

    /// EXIF DateTimeOriginal (falls back to DateTimeDigitized / TIFF DateTime).
    public static func captureDate(of url: URL) -> Date? {
        let props = properties(of: url)
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let raw = (exif[kCGImagePropertyExifDateTimeOriginal as String]
            ?? exif[kCGImagePropertyExifDateTimeDigitized as String]
            ?? tiff[kCGImagePropertyTIFFDateTime as String]) as? String
        return raw.flatMap(parseExifDate)
    }

    public static func cameraModel(of url: URL) -> String? {
        let tiff = properties(of: url)[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        return tiff?[kCGImagePropertyTIFFModel as String] as? String
    }

    /// Pixel width and height, already accounting for orientation.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        let props = properties(of: url)
        guard let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    private static func properties(of url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    // MARK: - ImageIO property dictionaries

    private static func section(_ title: String, _ entries: [MetadataEntry]) -> MetadataSection {
        MetadataSection(title: title, entries: entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
    }

    private static func entries(_ dictionary: [String: Any], prefix: String = "") -> [MetadataEntry] {
        dictionary.flatMap { key, value -> [MetadataEntry] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] { return entries(nested, prefix: path) }
            return [MetadataEntry(key: path, value: describe(value))]
        }
    }

    private static func sectionTitle(_ key: String) -> String {
        let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        switch name {
        case "Exif": return "EXIF"
        case "ExifAux": return "EXIF Aux"
        case "TIFF", "GPS", "IPTC", "JFIF", "PNG", "DNG", "CIFF", "HEIC": return name
        default:
            if name.hasPrefix("Maker") { return "Maker Notes (\(name.dropFirst("Maker".count)))" }
            return name
        }
    }

    static func describe(_ value: Any) -> String {
        let text: String
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        case let data as Data: text = "<\(data.count) bytes>"
        case let array as [Any]: text = array.map(describe).joined(separator: ", ")
        default: text = String(describing: value)
        }
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    // MARK: - XMP

    private static func xmpEntries(_ metadata: CGImageMetadata) -> [MetadataEntry] {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return tags.map { tag in
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? "?"
            let name = CGImageMetadataTagCopyName(tag) as String? ?? "?"
            return MetadataEntry(key: "\(prefix):\(name)", value: describeXMP(CGImageMetadataTagCopyValue(tag)))
        }
    }

    private static func describeXMP(_ value: CFTypeRef?) -> String {
        guard let value else { return "" }
        let typeID = CFGetTypeID(value)
        if typeID == CGImageMetadataTagGetTypeID() {
            return describeXMP(CGImageMetadataTagCopyValue(value as! CGImageMetadataTag))
        }
        if typeID == CFArrayGetTypeID() {
            return (value as! [AnyObject]).map { describeXMP($0) }.joined(separator: ", ")
        }
        if typeID == CFDictionaryGetTypeID() {
            let dictionary = value as! [String: AnyObject]
            return dictionary.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(describeXMP($0.value))" }
                .joined(separator: "; ")
        }
        return describe(value)
    }

    // MARK: - Formatting

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 0.3 { return "\(format(seconds)) s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    private static func formatGPS(_ gps: [String: Any]) -> String? {
        guard let lat = number(gps[kCGImagePropertyGPSLatitude as String]),
              let lon = number(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
        let fmt = { (v: Double) in v.formatted(.number.precision(.fractionLength(5))) }
        return "\(fmt(lat))° \(latRef), \(fmt(lon))° \(lonRef)"
    }
}

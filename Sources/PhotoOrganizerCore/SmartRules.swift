import Foundation
import UniformTypeIdentifiers

// MARK: - Fields and operators

/// What a smart-collection rule looks at.
public enum SmartField: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyword, anyText, fileName, title, caption, creator, copyright, location
    case rating, flag, label, fileType, camera, lens, captureDate, importDate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keyword: "Keyword"
        case .anyText: "Any text"
        case .fileName: "File name"
        case .title: "Title"
        case .caption: "Caption"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .location: "Location"
        case .rating: "Rating"
        case .flag: "Flag"
        case .label: "Label"
        case .fileType: "File type"
        case .camera: "Camera"
        case .lens: "Lens"
        case .captureDate: "Capture date"
        case .importDate: "Import date"
        }
    }

    public enum Kind: Sendable { case text, keyword, rating, flag, label, fileType, date }

    public var kind: Kind {
        switch self {
        case .keyword: .keyword
        case .anyText, .fileName, .title, .caption, .creator, .copyright, .location, .camera, .lens: .text
        case .rating: .rating
        case .flag: .flag
        case .label: .label
        case .fileType: .fileType
        case .captureDate, .importDate: .date
        }
    }

    public var operators: [SmartOperator] {
        switch kind {
        case .keyword: [.contains, .doesNotContain, .isEmpty, .isNotEmpty]
        case .text:
            switch self {
            case .anyText: [.contains, .doesNotContain]
            case .fileName: [.contains, .doesNotContain, .startsWith, .is]
            case .camera, .lens: [.is, .contains, .isEmpty]
            default: [.contains, .doesNotContain, .is, .isEmpty, .isNotEmpty]
            }
        case .rating: [.atLeast, .atMost, .equals]
        case .flag, .fileType: [.is, .isNot]
        case .label: [.is, .isNot, .isEmpty, .isNotEmpty]
        case .date: [.inLastDays, .on, .before, .after]
        }
    }

    /// Needs the photo's EXIF (read on demand, so plain tag rules stay fast).
    public var needsMetadata: Bool { self == .camera || self == .lens || self == .captureDate }

    /// A sensible value when the field is first chosen.
    public var defaultValue: String {
        switch kind {
        case .rating: "3"
        case .flag: "picked"
        case .label: ColorLabel.red.rawValue
        case .fileType: "raw"
        case .date: "7"
        default: ""
        }
    }
}

public enum SmartOperator: String, Codable, CaseIterable, Sendable {
    case contains, doesNotContain, `is`, isNot, startsWith, isEmpty, isNotEmpty
    case atLeast, atMost, equals
    case on, before, after, inLastDays

    public var displayName: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "doesn't contain"
        case .is: "is"
        case .isNot: "is not"
        case .startsWith: "starts with"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .atLeast: "is at least"
        case .atMost: "is at most"
        case .equals: "is exactly"
        case .on: "is on"
        case .before: "is before"
        case .after: "is after"
        case .inLastDays: "is in the last"
        }
    }

    /// Label used for keyword / label fields where "empty" reads better as "none".
    public func displayName(for field: SmartField) -> String {
        switch (field.kind, self) {
        case (.keyword, .isEmpty): "has none"
        case (.keyword, .isNotEmpty): "has any"
        case (.label, .isEmpty): "is none"
        case (.label, .isNotEmpty): "is any color"
        default: displayName
        }
    }

    public var takesValue: Bool { self != .isEmpty && self != .isNotEmpty }
}

/// File types offered by the "File type" rule.
public enum SmartFileType: String, CaseIterable, Identifiable, Sendable {
    case raw, jpeg, heic, tiff, psd, png
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .psd: "Photoshop (PSD)"
        case .png: "PNG"
        }
    }

    static func of(_ url: URL) -> SmartFileType? {
        if Sidecar.isRaw(url) { return .raw }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .tiff) { return .tiff }
        if type.conforms(to: .png) { return .png }
        if type.identifier == "com.adobe.photoshop-image" || url.pathExtension.lowercased() == "psd" { return .psd }
        return nil
    }
}

// MARK: - Rules

public struct SmartRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var field: SmartField
    public var op: SmartOperator
    /// Text, a number (rating, days), "picked"/"unflagged"/"rejected", a label name, a file type,
    /// or a date as yyyy-MM-dd.
    public var value: String

    public init(id: UUID = UUID(), field: SmartField, op: SmartOperator? = nil, value: String? = nil) {
        self.id = id
        self.field = field
        self.op = op ?? field.operators[0]
        self.value = value ?? field.defaultValue
    }
}

/// A smart collection's conditions: all (or any) of the rules must match.
public struct SmartRules: Codable, Hashable, Sendable {
    public var matchAll = true
    public var rules: [SmartRule] = []

    public init(matchAll: Bool = true, rules: [SmartRule] = []) {
        self.matchAll = matchAll
        self.rules = rules
    }

    /// The rules equivalent to a search from the filter bar (also used to convert smart
    /// collections saved before rules existed).
    public init(criteria: SearchCriteria) {
        var rules: [SmartRule] = []
        let text = criteria.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { rules.append(SmartRule(field: .anyText, op: .contains, value: text)) }
        if criteria.minimumRating > 0 { rules.append(SmartRule(field: .rating, op: .atLeast, value: String(criteria.minimumRating))) }
        if let label = criteria.label { rules.append(SmartRule(field: .label, op: .is, value: label.rawValue)) }
        switch criteria.flag {
        case .any: break
        case .picked: rules.append(SmartRule(field: .flag, op: .is, value: "picked"))
        case .unflagged: rules.append(SmartRule(field: .flag, op: .is, value: "unflagged"))
        case .rejected: rules.append(SmartRule(field: .flag, op: .is, value: "rejected"))
        case .notRejected: rules.append(SmartRule(field: .flag, op: .isNot, value: "rejected"))
        }
        for keyword in criteria.keywords { rules.append(SmartRule(field: .keyword, op: .contains, value: keyword)) }
        self.init(matchAll: true, rules: rules)
    }

    public var needsMetadata: Bool { rules.contains { $0.field.needsMetadata } }
    public var usesImportDate: Bool { rules.contains { $0.field == .importDate } }

    /// No rules matches everything.
    public func matches(_ photo: PhotoFacts, now: Date = Date()) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(photo, now: now) }
                        : rules.contains { $0.matches(photo, now: now) }
    }
}

/// What a rule can know about a photo. Metadata fields are nil when they weren't loaded or the
/// file doesn't have them.
public struct PhotoFacts: Sendable {
    public let url: URL
    public let tags: PhotoTags
    public var captureDate: Date?
    public var importDate: Date?
    public var camera: String?
    public var lens: String?

    public init(url: URL, tags: PhotoTags, captureDate: Date? = nil, importDate: Date? = nil,
                camera: String? = nil, lens: String? = nil) {
        self.url = url
        self.tags = tags
        self.captureDate = captureDate
        self.importDate = importDate
        self.camera = camera
        self.lens = lens
    }
}

extension SmartRule {
    public func matches(_ photo: PhotoFacts, now: Date = Date()) -> Bool {
        let tags = photo.tags
        switch field {
        case .keyword:
            let has = tags.keywords.contains { Keyword.matches($0, query: value) }
            switch op {
            case .contains: return has
            case .doesNotContain: return !has
            case .isEmpty: return tags.keywords.isEmpty
            case .isNotEmpty: return !tags.keywords.isEmpty
            default: return false
            }
        case .anyText:
            let haystack = [photo.url.lastPathComponent] + tags.keywords + Array(tags.fields.values)
            let has = haystack.contains { $0.localizedCaseInsensitiveContains(value) }
            return op == .doesNotContain ? !has : has
        case .fileName: return matchText(photo.url.lastPathComponent)
        case .title: return matchText(tags[.title])
        case .caption: return matchText(tags[.caption])
        case .creator: return matchText(tags[.creator])
        case .copyright: return matchText(tags[.copyright])
        case .location:
            return matchText([tags[.location], tags[.city], tags[.state], tags[.country]]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        case .camera: return matchText(photo.camera ?? "")
        case .lens: return matchText(photo.lens ?? "")
        case .rating:
            guard let target = Int(value) else { return false }
            switch op {
            case .atLeast: return tags.rating >= target
            case .atMost: return tags.rating >= 0 && tags.rating <= target   // rejects aren't "low rated"
            case .equals: return tags.rating == target
            default: return false
            }
        case .flag:
            let state = tags.isRejected ? "rejected" : tags.isPicked ? "picked" : "unflagged"
            return op == .isNot ? state != value : state == value
        case .label:
            switch op {
            case .is: return tags.label?.rawValue == value
            case .isNot: return tags.label?.rawValue != value
            case .isEmpty: return tags.label == nil
            case .isNotEmpty: return tags.label != nil
            default: return false
            }
        case .fileType:
            let type = SmartFileType.of(photo.url)?.rawValue
            return op == .isNot ? type != value : type == value
        case .captureDate: return matchDate(photo.captureDate, now: now)
        case .importDate: return matchDate(photo.importDate, now: now)
        }
    }

    private func matchText(_ text: String) -> Bool {
        switch op {
        case .contains: text.localizedCaseInsensitiveContains(value)
        case .doesNotContain: !text.localizedCaseInsensitiveContains(value)
        case .is: text.caseInsensitiveCompare(value) == .orderedSame
        case .startsWith: text.lowercased().hasPrefix(value.lowercased())
        case .isEmpty: text.isEmpty
        case .isNotEmpty: !text.isEmpty
        default: false
        }
    }

    private func matchDate(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        switch op {
        case .inLastDays:
            guard let days = Int(value), let start = calendar.date(byAdding: .day, value: -days, to: now) else { return false }
            return date >= start && date <= now.addingTimeInterval(60)
        case .on, .before, .after:
            guard let day = SmartRule.dayFormatter.date(from: value) else { return false }
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            switch op {
            case .on: return date >= start && date < end
            case .before: return date < start
            default: return date >= end
            }
        default:
            return false
        }
    }

    /// yyyy-MM-dd in local time, for date rule values.
    public static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

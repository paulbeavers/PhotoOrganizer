import Foundation

/// Color labels, stored in `xmp:Label` using the Lightroom/Camera Raw names ("Red", "Yellow", ...).
public enum ColorLabel: String, CaseIterable, Codable, Sendable, Identifiable {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"

    public var id: String { rawValue }

    /// Parses an `xmp:Label` value. Accepts both the Lightroom names and
    /// Adobe Bridge's default label names ("Select", "Second", ...).
    public init?(xmpValue: String) {
        switch xmpValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "red", "select": self = .red
        case "yellow", "second": self = .yellow
        case "green", "approved": self = .green
        case "blue", "review": self = .blue
        case "purple", "to do": self = .purple
        default: return nil
        }
    }
}

/// Descriptive IPTC fields, stored in the XMP properties Adobe apps use.
public enum IPTCField: String, CaseIterable, Codable, Sendable, Identifiable {
    case title, headline, caption, creator, copyright, location, city, state, country

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .headline: "Headline"
        case .caption: "Caption"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .location: "Sublocation"
        case .city: "City"
        case .state: "State / Province"
        case .country: "Country"
        }
    }

    public var isMultiline: Bool { self == .caption }
}

/// The user-editable organizational data for a photo.
public struct PhotoTags: Equatable, Hashable, Sendable {
    /// -1 = rejected, 0 = unrated, 1...5 stars. Stored in `xmp:Rating` (Bridge uses -1 for rejects too).
    public var rating: Int
    /// Pick flag for culling. Adobe has no standard XMP field for this, so it is stored in this app's
    /// own namespace; other apps ignore it.
    public var isPicked: Bool
    public var label: ColorLabel?
    /// Keywords. Hierarchical keywords use "|" between levels, as in Lightroom ("Places|Iceland|Vík").
    public var keywords: [String]
    public var fields: [IPTCField: String]

    public init(rating: Int = 0, isPicked: Bool = false, label: ColorLabel? = nil,
                keywords: [String] = [], fields: [IPTCField: String] = [:]) {
        self.rating = rating
        self.isPicked = isPicked
        self.label = label
        self.keywords = keywords
        self.fields = fields
        normalize()
    }

    public static let empty = PhotoTags()

    public var isRejected: Bool { rating < 0 }

    public subscript(field: IPTCField) -> String {
        get { fields[field] ?? "" }
        set { fields[field] = newValue }
    }

    /// Clamps the rating, normalizes keyword paths, drops duplicate keywords (case-insensitively,
    /// keeping first spelling and order) and removes empty fields.
    public mutating func normalize() {
        rating = min(max(rating, -1), 5)
        if rating < 0 { isPicked = false }
        var seen = Set<String>()
        keywords = keywords.compactMap { raw in
            let keyword = Keyword.normalize(raw)
            guard !keyword.isEmpty, seen.insert(keyword.lowercased()).inserted else { return nil }
            return keyword
        }
        fields = fields.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Culling

    public mutating func pick() {
        isPicked = true
        if rating < 0 { rating = 0 }
    }

    public mutating func reject() {
        isPicked = false
        rating = -1
    }

    public mutating func unflag() {
        isPicked = false
        if rating < 0 { rating = 0 }
    }

    /// Splits user input such as "landscape, sunset; Places > Iceland" into keywords.
    public static func parseKeywords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { Keyword.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}

/// Helpers for hierarchical keyword paths ("Places|Iceland|Vík").
public enum Keyword {
    public static let separator: Character = "|"

    /// Accepts "|", ">" or "›" as level separators and trims each level.
    public static func normalize(_ raw: String) -> String {
        components(raw).joined(separator: String(separator))
    }

    public static func components(_ keyword: String) -> [String] {
        keyword.split(whereSeparator: { $0 == "|" || $0 == ">" || $0 == "›" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func leaf(_ keyword: String) -> String {
        components(keyword).last ?? keyword
    }

    /// "Places|Iceland" -> "Places › Iceland"
    public static func display(_ keyword: String) -> String {
        components(keyword).joined(separator: " › ")
    }

    /// Whether a photo keyword satisfies a keyword query: the photo has the query keyword or one of
    /// its descendants; a single-level query also matches that term at any level.
    public static func matches(_ keyword: String, query: String) -> Bool {
        let k = components(keyword).map { $0.lowercased() }
        let q = components(query).map { $0.lowercased() }
        guard !q.isEmpty else { return false }
        if k.starts(with: q) { return true }
        return q.count == 1 && k.contains(q[0])
    }

    /// All keywords to write to flat `dc:subject`: every level of every path, so apps that don't
    /// understand hierarchy can still find "Iceland".
    public static func flattened(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for component in keywords.flatMap(components) where seen.insert(component.lowercased()).inserted {
            result.append(component)
        }
        return result
    }
}

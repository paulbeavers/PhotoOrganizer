import Foundation

/// Culling-flag filter.
public enum FlagFilter: String, Codable, CaseIterable, Sendable, Identifiable {
    case any, picked, unflagged, rejected, notRejected

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .any: "Any Flag"
        case .picked: "Picked"
        case .unflagged: "Unflagged"
        case .rejected: "Rejected"
        case .notRejected: "Hide Rejected"
        }
    }

    func matches(_ tags: PhotoTags) -> Bool {
        switch self {
        case .any: true
        case .picked: tags.isPicked
        case .unflagged: !tags.isPicked && !tags.isRejected
        case .rejected: tags.isRejected
        case .notRejected: !tags.isRejected
        }
    }
}

/// A photo filter. Used live in the browser, and saved inside smart collections.
public struct SearchCriteria: Codable, Equatable, Hashable, Sendable {
    /// Free text matched against file name, keywords and IPTC text fields.
    public var text: String = ""
    public var minimumRating: Int = 0
    public var label: ColorLabel?
    public var flag: FlagFilter = .any
    /// Every keyword must match (a parent keyword matches its children).
    public var keywords: [String] = []

    public init(text: String = "", minimumRating: Int = 0, label: ColorLabel? = nil,
                flag: FlagFilter = .any, keywords: [String] = []) {
        self.text = text
        self.minimumRating = minimumRating
        self.label = label
        self.flag = flag
        self.keywords = keywords
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && minimumRating == 0 && label == nil
            && flag == .any && keywords.isEmpty
    }

    public func matches(name: String, tags: PhotoTags) -> Bool {
        if minimumRating > 0, tags.rating < minimumRating { return false }
        if let label, tags.label != label { return false }
        if !flag.matches(tags) { return false }
        for query in keywords where !tags.keywords.contains(where: { Keyword.matches($0, query: query) }) {
            return false
        }
        let query = text.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let haystack = [name] + tags.keywords + Array(tags.fields.values)
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return true
    }

    // Tolerate missing keys so older/hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        minimumRating = try c.decodeIfPresent(Int.self, forKey: .minimumRating) ?? 0
        label = try c.decodeIfPresent(ColorLabel.self, forKey: .label)
        flag = try c.decodeIfPresent(FlagFilter.self, forKey: .flag) ?? .any
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

/// A named set of photos, saved as a JSON file in the data folder.
///
/// - Manual collections list photos explicitly.
/// - Smart collections are saved searches: every photo under `folders` that matches `criteria`.
public struct PhotoCollection: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case manual, smart }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Manual: photo paths, stored portably (see `PortablePath`).
    public var items: [String]
    /// Smart: folders to search (portable paths, searched recursively). Empty = all sidebar folders.
    public var folders: [String]
    public var criteria: SearchCriteria
    public var created: Date

    public init(id: UUID = UUID(), name: String, kind: Kind, items: [String] = [], folders: [String] = [],
                criteria: SearchCriteria = SearchCriteria(), created: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.items = items
        self.folders = folders
        self.criteria = criteria
        // Whole seconds, so the value survives an ISO-8601 round trip unchanged.
        self.created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
    }

    public var itemURLs: [URL] { items.map(PortablePath.url) }
    public var folderURLs: [URL] { folders.map(PortablePath.url) }

    public mutating func add(_ urls: [URL]) {
        let existing = Set(items)
        items += urls.map(PortablePath.string).filter { !existing.contains($0) }
    }

    public mutating func remove(_ urls: [URL]) {
        let removed = Set(urls.map(PortablePath.string))
        items.removeAll { removed.contains($0) }
    }

    /// Keeps manual collections pointing at photos after they are moved or renamed in the app.
    @discardableResult
    public mutating func relocate(_ moves: [URL: URL]) -> Bool {
        var changed = false
        let map = Dictionary(moves.map { (PortablePath.string($0.key), PortablePath.string($0.value)) },
                             uniquingKeysWith: { a, _ in a })
        for index in items.indices {
            if let moved = map[items[index]] { items[index] = moved; changed = true }
        }
        return changed
    }
}

/// Stores paths under the user's home folder as "~/…" so collection files keep working when the
/// data folder is synced to another Mac with the same folder layout.
public enum PortablePath {
    public static var homeDirectory: URL {
        // In a sandboxed app NSHomeDirectory() points into the container; use the real home folder.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func string(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = homeDirectory.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func url(_ string: String) -> URL {
        if string == "~" { return homeDirectory }
        if string.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(string.dropFirst(2))) }
        return URL(fileURLWithPath: string)
    }
}

/// Reads and writes collections as `<Name>.json` files in a folder.
public struct CollectionStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func loadAll() -> [PhotoCollection] {
        files().map(\.collection)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes the collection. If it was renamed, its old file is removed.
    public func save(_ collection: PhotoCollection) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = fileURL(for: collection)
        for existing in files() where existing.collection.id == collection.id && existing.url != target {
            try? FileManager.default.removeItem(at: existing.url)
        }
        try Self.encoder.encode(collection).write(to: target, options: .atomic)
    }

    public func delete(_ collection: PhotoCollection) throws {
        for existing in files() where existing.collection.id == collection.id {
            try FileManager.default.removeItem(at: existing.url)
        }
    }

    private func fileURL(for collection: PhotoCollection) -> URL {
        var base = RenamePlan.sanitize(collection.name)
        if base.isEmpty { base = "Untitled" }
        // Another collection already using this file name? Disambiguate with the id.
        let candidate = folder.appendingPathComponent(base).appendingPathExtension("json")
        if let owner = files().first(where: { $0.url == candidate }), owner.collection.id != collection.id {
            return folder.appendingPathComponent("\(base) \(collection.id.uuidString.prefix(8))").appendingPathExtension("json")
        }
        return candidate
    }

    private func files() -> [(url: URL, collection: PhotoCollection)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let collection = try? Self.decoder.decode(PhotoCollection.self, from: data) else { return nil }
            return (url, collection)
        }
    }
}

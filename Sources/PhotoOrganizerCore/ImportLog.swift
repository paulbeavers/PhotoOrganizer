import Foundation

/// One import: when it ran, where from, and which photos it brought in. Each import is a small
/// JSON file in `<data folder>/Imports/`, so the list syncs between Macs without merge conflicts.
public struct ImportSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var started: Date
    public var finished: Date?
    /// Card or folder name, e.g. "NIKON Z 8".
    public var source: String
    /// Imported photos, as portable paths (see `PortablePath`).
    public var files: [String]

    public init(id: UUID = UUID(), started: Date = Date(), finished: Date? = nil, source: String, files: [String] = []) {
        self.id = id
        // Whole seconds, so the value survives an ISO-8601 round trip unchanged.
        self.started = Date(timeIntervalSince1970: started.timeIntervalSince1970.rounded(.down))
        self.finished = finished.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.source = source
        self.files = files
    }

    public var fileURLs: [URL] { files.map(PortablePath.url) }

    /// Follows photos the app moved or renamed (e.g. into a day's Picked folder). Returns whether
    /// anything changed.
    public mutating func relocate(_ moves: [URL: URL]) -> Bool {
        let map = Dictionary(moves.map { (PortablePath.string($0.key).lowercased(), PortablePath.string($0.value)) },
                             uniquingKeysWith: { a, _ in a })
        var changed = false
        for index in files.indices {
            if let moved = map[files[index].lowercased()] { files[index] = moved; changed = true }
        }
        return changed
    }
}

public struct ImportLog: Sendable {
    public let folder: URL

    public init(dataFolder: URL) {
        folder = dataFolder.appendingPathComponent("Imports", isDirectory: true)
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

    /// Newest first.
    public func loadAll() -> [ImportSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(ImportSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    /// Saves as `yyyy-MM-dd_HH-mm-ss.json` (no spaces); replaces an earlier file for the same session.
    public func save(_ session: ImportSession) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Self.fileName(for: session))
        try Self.encoder.encode(session).write(to: target, options: .atomic)
        // The name has the local time in it: a file saved on a Mac in another time zone (synced
        // data folder) has a different name for the same import. Keep one file per import.
        for other in files(for: session) where other.lastPathComponent != target.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
    }

    public func delete(_ session: ImportSession) throws {
        for file in files(for: session) { try FileManager.default.removeItem(at: file) }
    }

    /// Every file in the folder that holds this import (normally one).
    private func files(for session: ImportSession) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.filter { url in
            (try? Self.decoder.decode(ImportSession.self, from: Data(contentsOf: url)))?.id == session.id
        }
    }

    static func fileName(for session: ImportSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: session.started) + "_" + session.id.uuidString.prefix(8) + ".json"
    }

    /// Lower-cased portable path → when it was imported (newest import wins).
    public static func importDates(_ sessions: [ImportSession]) -> [String: Date] {
        var dates: [String: Date] = [:]
        for session in sessions.reversed() {   // oldest first, so newer imports overwrite
            for file in session.files { dates[file.lowercased()] = session.started }
        }
        return dates
    }

    /// When a file arrived in its folder: macOS's "date added". (Not the creation date: an import
    /// keeps the photo's original modification date, and macOS then moves the creation date back to
    /// match, so it shows when the photo was taken rather than when it was imported.)
    public static func dateAdded(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    /// Imports made before the log existed, rebuilt from `ImportHistory.json`: the imported files
    /// that still exist, grouped by when they were added to their folder (a gap of more than 15
    /// minutes starts a new import).
    public static func reconstruct(history: [String: String], source: String = "Earlier import") -> [ImportSession] {
        let files: [(path: String, date: Date)] = Set(history.values).compactMap { path in
            let url = PortablePath.url(path)
            guard let date = dateAdded(url) else { return nil }
            return (path, date)
        }
        .sorted { $0.date < $1.date }
        var sessions: [ImportSession] = []
        var current: [(path: String, date: Date)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            sessions.append(ImportSession(started: first.date, finished: last.date, source: source, files: current.map(\.path)))
            current = []
        }
        for file in files {
            if let last = current.last, file.date.timeIntervalSince(last.date) > 15 * 60 { flush() }
            current.append(file)
        }
        flush()
        return sessions.sorted { $0.started > $1.started }
    }
}

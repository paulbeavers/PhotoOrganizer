import Foundation

/// Light or dark windows, or follow the system setting.
/// Which file of a stack is shown on top (its cover in the grid).
public enum StackCover: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The most recent export (e.g. a TIFF saved from NX Studio), so edited photos look edited.
    case newestExport
    /// Always the RAW file.
    case raw

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .newestExport: "Newest export"
        case .raw: "RAW file"
        }
    }
}

public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// App configuration stored as `Settings.json` in the data folder, so it travels with the data
/// folder to other Macs.
///
/// Anything that only makes sense on one Mac stays out of here: where the data folder itself is,
/// sandbox access grants (bookmarks are machine-specific), view state and caches.
public struct SharedSettings: Codable, Equatable, Sendable {
    public var version = 1
    /// Sidebar folders as portable paths ("~/Pictures/…" or absolute, e.g. "/Volumes/Photos").
    public var sidebarFolders: [String] = []
    public var editors: [ExternalEditor] = []
    public var defaultEditorID: UUID?
    /// Move to the next photo after rating or flagging.
    public var autoAdvance = true
    /// Show the contents of all subfolders in the grid.
    public var includeSubfolders = false
    public var renameTemplate = "{date:yyyyMMdd}_{n:4}"
    public var appearance: AppAppearance = .system
    /// Show files with the same name in one folder (a RAW+JPEG pair) as one stack in the grid.
    public var stackSameName = true
    /// Which file is on top of a stack.
    public var stackCover: StackCover = .newestExport
    /// Options for importing from cards and folders.
    public var importOptions = ImportSettings()

    public init() {}

    public var sidebarFolderURLs: [URL] { sidebarFolders.map(PortablePath.url) }

    // Tolerate missing keys so older or hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SharedSettings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        sidebarFolders = try c.decodeIfPresent([String].self, forKey: .sidebarFolders) ?? d.sidebarFolders
        editors = try c.decodeIfPresent([ExternalEditor].self, forKey: .editors) ?? d.editors
        defaultEditorID = try c.decodeIfPresent(UUID.self, forKey: .defaultEditorID)
        autoAdvance = try c.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? d.autoAdvance
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? d.includeSubfolders
        renameTemplate = try c.decodeIfPresent(String.self, forKey: .renameTemplate) ?? d.renameTemplate
        // An unknown value (e.g. from a newer version on another Mac) falls back to System.
        appearance = (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? d.appearance
        stackSameName = try c.decodeIfPresent(Bool.self, forKey: .stackSameName) ?? d.stackSameName
        stackCover = (try? c.decodeIfPresent(StackCover.self, forKey: .stackCover)) ?? d.stackCover
        importOptions = (try? c.decodeIfPresent(ImportSettings.self, forKey: .importOptions)) ?? d.importOptions
    }
}

/// Reads and writes `Settings.json` in a folder.
public struct SharedSettingsStore: Sendable {
    public let folder: URL
    public var fileURL: URL { folder.appendingPathComponent("Settings.json") }

    public init(folder: URL) {
        self.folder = folder
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// `nil` if the file doesn't exist or can't be parsed.
    public func load() -> SharedSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SharedSettings.self, from: data)
    }

    public func save(_ settings: SharedSettings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }

    public var modificationDate: Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

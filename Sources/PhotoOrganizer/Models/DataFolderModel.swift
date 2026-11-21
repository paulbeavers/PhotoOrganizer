import AppKit
import Observation
import PhotoOrganizerCore
import UniformTypeIdentifiers

/// The data folder: a plain folder of files holding what the app creates beyond per-photo sidecars.
/// It is not a database or catalog. Every file is readable on its own and can be copied, synced or
/// edited by hand.
///
/// ```
/// Photo Organizer/
///   Settings.json             sidebar folders, external editors, preferences
///   Collections/<Name>.json   manual collections and smart collections (saved searches)
///   Keywords.txt              keyword list (Lightroom / Bridge tab-indented format)
/// ```
/// Point it at a synced folder (iCloud Drive, Dropbox, a NAS) to share everything between Macs.
/// Only the data folder's own location, sandbox access grants, view state and caches stay local.
@MainActor
@Observable
final class DataFolderModel {
    private enum Keys {
        static let bookmark = "dataFolderBookmark"
        static let legacyBookmark = "libraryFolderBookmark"  // v0.2
    }

    private(set) var url: URL
    private(set) var collections: [PhotoCollection] = []
    private(set) var keywords = KeywordList()
    private(set) var settings = SharedSettings()
    /// Every import, newest first (one file each in `Imports/`).
    private(set) var importSessions: [ImportSession] = []
    var errorMessage: String?
    @ObservationIgnored private var hasLoadedSettings = false

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: Keys.bookmark) ?? defaults.data(forKey: Keys.legacyBookmark)
        if let stored, let resolved = FolderAccess.resolve(stored) {
            url = resolved.url
            defaults.set(resolved.refreshed ?? stored, forKey: Keys.bookmark)
        } else {
            url = Self.defaultURL
            Self.migrateLegacyDefaultFolder()
        }
        defaults.removeObject(forKey: Keys.legacyBookmark)
        reload()
    }

    static var defaultURL: URL {
        PortablePath.homeDirectory.appendingPathComponent("Pictures/Photo Organizer", isDirectory: true)
    }

    /// v0.2 used "~/Pictures/Photo Organizer Library". Rename it if it exists and the new one doesn't.
    private static func migrateLegacyDefaultFolder() {
        let legacy = PortablePath.homeDirectory.appendingPathComponent("Pictures/Photo Organizer Library", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: defaultURL.path) else { return }
        try? fm.moveItem(at: legacy, to: defaultURL)
    }

    var collectionsFolder: URL { url.appendingPathComponent("Collections", isDirectory: true) }
    /// Where imports go: `images/YYYY/yyyy-MM-dd/Imported/` (see `ImportLayout`, `CullFolders`).
    var imagesURL: URL { url.appendingPathComponent(ImportLayout.rootFolderName, isDirectory: true) }
    var keywordsFile: URL { url.appendingPathComponent("Keywords.txt") }
    var settingsFile: URL { settingsStore.fileURL }
    private var store: CollectionStore { CollectionStore(folder: collectionsFolder) }
    private var settingsStore: SharedSettingsStore { SharedSettingsStore(folder: url) }

    /// Re-reads everything from disk. Called at launch, when the data folder changes, and whenever
    /// the app becomes active (to pick up changes synced from another Mac).
    func reload() {
        loadSettings()
        let loadedCollections = store.loadAll()
        if loadedCollections != collections { collections = loadedCollections }
        let text = (try? String(contentsOf: keywordsFile, encoding: .utf8)) ?? ""
        let loadedKeywords = KeywordList(text: text)
        if loadedKeywords != keywords { keywords = loadedKeywords }
        loadImportSessions()
    }

    // MARK: - Imports

    private var importLog: ImportLog { ImportLog(dataFolder: url) }

    private func loadImportSessions() {
        let log = importLog
        // Imports made before the log existed: rebuild them once from ImportHistory.json.
        if !FileManager.default.fileExists(atPath: log.folder.path) {
            let history = ImportHistory(dataFolder: url).load()
            if !history.isEmpty {
                for session in ImportLog.reconstruct(history: history) { try? log.save(session) }
            }
        }
        let loaded = log.loadAll()
        if loaded != importSessions { importSessions = loaded }
    }

    func importSession(_ id: UUID) -> ImportSession? {
        importSessions.first { $0.id == id }
    }

    func saveImportSession(_ session: ImportSession) {
        do {
            try importLog.save(session)
            loadImportSessions()
        } catch {
            errorMessage = "Couldn't record the import: \(error.localizedDescription)"
        }
    }

    /// Removes an import from the list (the photos themselves stay).
    func removeImportSession(_ session: ImportSession) {
        try? importLog.delete(session)
        loadImportSessions()
    }

    // MARK: - Settings.json

    /// Applies the Light / Dark / System choice to every window (including Settings).
    func applyAppearance() {
        let appearance: NSAppearance? = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if NSApplication.shared.appearance != appearance { NSApplication.shared.appearance = appearance }
    }

    /// Changes settings and saves `Settings.json` immediately.
    func updateSettings(_ change: (inout SharedSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        do {
            try settingsStore.save(updated)
        } catch {
            errorMessage = "Couldn't save Settings.json: \(error.localizedDescription)"
        }
    }

    private func loadSettings() {
        let store = settingsStore
        if let loaded = store.load() {
            if loaded != settings { settings = loaded }
            hasLoadedSettings = true
            return
        }
        if store.exists {
            // Don't overwrite a file we can't parse (e.g. a sync conflict); keep what we have.
            errorMessage = "Settings.json in the data folder couldn't be read, so it was left unchanged. Fix or delete it to save settings again."
            if !hasLoadedSettings { settings = Self.legacyLocalSettings() }
            hasLoadedSettings = true
            return
        }
        // No settings file in this folder yet: on first launch, move this Mac's old local settings
        // into it; when switching to an empty folder, carry the current settings over.
        if !hasLoadedSettings { settings = Self.legacyLocalSettings() }
        hasLoadedSettings = true
        do {
            try store.save(settings)
            Self.removeLegacyLocalSettings()
        } catch {
            errorMessage = "Couldn't create Settings.json: \(error.localizedDescription)"
        }
    }

    private enum LegacyKeys {
        static let rootBookmarks = "rootFolderBookmarks"
        static let rootPaths = "rootFolders"
        static let editors = "externalEditors"
        static let defaultEditor = "defaultEditorID"
        static let autoAdvance = "autoAdvance"
        static let includeSubfolders = "includeSubfolders"
        static let renameTemplate = "renameTemplate"
        static let all = [rootBookmarks, rootPaths, editors, defaultEditor, autoAdvance, includeSubfolders, renameTemplate]
    }

    /// Settings as earlier versions stored them in this Mac's user defaults (or first-run defaults).
    private static func legacyLocalSettings() -> SharedSettings {
        let defaults = UserDefaults.standard
        var settings = SharedSettings()

        var roots: [URL] = []
        if let bookmarks = defaults.array(forKey: LegacyKeys.rootBookmarks) as? [Data] {
            for bookmark in bookmarks {
                guard let resolved = FolderAccess.resolve(bookmark) else { continue }
                roots.append(resolved.url)
                FolderAccess.storeGrant(resolved.refreshed ?? bookmark, for: resolved.url)
            }
        } else if let paths = defaults.stringArray(forKey: LegacyKeys.rootPaths) {
            roots = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        if roots.isEmpty {
            roots = [PortablePath.homeDirectory.appendingPathComponent("Pictures", isDirectory: true)]
        }
        settings.sidebarFolders = roots.map(PortablePath.string)

        if let data = defaults.data(forKey: LegacyKeys.editors),
           let editors = try? JSONDecoder().decode([ExternalEditor].self, from: data) {
            settings.editors = editors.map { editor in
                var editor = editor
                if editor.bundleIdentifier == nil { editor.bundleIdentifier = Bundle(url: editor.appURL)?.bundleIdentifier }
                return editor
            }
            settings.defaultEditorID = defaults.string(forKey: LegacyKeys.defaultEditor).flatMap(UUID.init(uuidString:))
        } else {
            settings.editors = EditorSettings.discoverEditors()
            settings.defaultEditorID = settings.editors.first { $0.fileExtensions.isEmpty }?.id
        }
        if let autoAdvance = defaults.object(forKey: LegacyKeys.autoAdvance) as? Bool { settings.autoAdvance = autoAdvance }
        settings.includeSubfolders = defaults.bool(forKey: LegacyKeys.includeSubfolders)
        if let template = defaults.string(forKey: LegacyKeys.renameTemplate) { settings.renameTemplate = template }
        return settings
    }

    private static func removeLegacyLocalSettings() {
        for key in LegacyKeys.all { UserDefaults.standard.removeObject(forKey: key) }
    }

    func chooseFolderInteractively() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Use This Folder"
        panel.message = "Choose where to keep settings, collections and the keyword list. If the folder already has them (e.g. synced from another Mac), they are used as they are; otherwise your current settings are copied there."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if let bookmark = FolderAccess.grant(chosen) { UserDefaults.standard.set(bookmark, forKey: Keys.bookmark) }
        url = chosen
        reload()
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Collections

    func collection(_ id: UUID) -> PhotoCollection? {
        collections.first { $0.id == id }
    }

    @discardableResult
    func save(_ collection: PhotoCollection) -> Bool {
        do {
            try store.save(collection)
            if let index = collections.firstIndex(where: { $0.id == collection.id }) {
                collections[index] = collection
            } else {
                collections.append(collection)
            }
            collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return true
        } catch {
            errorMessage = "Couldn't save collection “\(collection.name)”: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ collection: PhotoCollection) {
        do {
            try store.delete(collection)
            collections.removeAll { $0.id == collection.id }
        } catch {
            errorMessage = "Couldn't delete collection “\(collection.name)”: \(error.localizedDescription)"
        }
    }

    func add(_ urls: [URL], to id: UUID) {
        guard var collection = collection(id) else { return }
        collection.add(urls)
        save(collection)
    }

    func remove(_ urls: [URL], from id: UUID) {
        guard var collection = collection(id) else { return }
        collection.remove(urls)
        save(collection)
    }

    /// Keeps manual collections and the import list pointing at photos the app moved or renamed.
    func relocate(_ moves: [URL: URL]) {
        guard !moves.isEmpty else { return }
        for var collection in collections where collection.kind == .manual {
            if collection.relocate(moves) { save(collection) }
        }
        var sessionsChanged = false
        for var session in importSessions where session.relocate(moves) {
            do { try importLog.save(session); sessionsChanged = true }
            catch { errorMessage = "Couldn't update the import list: \(error.localizedDescription)" }
        }
        if sessionsChanged { loadImportSessions() }
    }

    // MARK: - Keywords

    func addKeyword(_ path: String) {
        let normalized = Keyword.normalize(path)
        guard !normalized.isEmpty else { return }
        keywords.add(normalized)
        saveKeywords()
    }

    func addKeywords(_ paths: [String]) {
        for path in paths { keywords.add(path) }
        saveKeywords()
    }

    func removeKeyword(_ path: String) {
        keywords.remove(path)
        saveKeywords()
    }

    func importKeywordsInteractively() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.prompt = "Import"
        panel.message = "Choose a keyword list exported from Lightroom or Bridge (tab-indented text)."
        guard panel.runModal() == .OK, let file = panel.url,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        addKeywords(KeywordList(text: text).paths)
    }

    func exportKeywordsInteractively() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Keywords.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try keywords.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't export keywords: \(error.localizedDescription)"
        }
    }

    private func saveKeywords() {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try keywords.text.write(to: keywordsFile, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't save the keyword list: \(error.localizedDescription)"
        }
    }
}

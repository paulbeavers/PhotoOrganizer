import AppKit
import Observation
import PhotoOrganizerCore
import UniformTypeIdentifiers

/// The library folder: plain files that hold everything the app creates beyond per-photo sidecars.
///
/// ```
/// Photo Organizer Library/
///   Collections/<Name>.json   manual collections and smart collections (saved searches)
///   Keywords.txt              keyword vocabulary (Lightroom / Bridge tab-indented format)
/// ```
/// Point it at a synced folder (iCloud Drive, Dropbox, a NAS) to share it between Macs.
@MainActor
@Observable
final class LibraryModel {
    private enum Keys {
        static let bookmark = "libraryFolderBookmark"
    }

    private(set) var folder: URL
    private(set) var collections: [PhotoCollection] = []
    private(set) var keywords = KeywordLibrary()
    var errorMessage: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.bookmark), let resolved = FolderAccess.resolve(data) {
            folder = resolved.url
            if let refreshed = resolved.refreshed { UserDefaults.standard.set(refreshed, forKey: Keys.bookmark) }
        } else {
            folder = Self.defaultFolder
        }
        reload()
    }

    static var defaultFolder: URL {
        PortablePath.homeDirectory.appendingPathComponent("Pictures/Photo Organizer Library", isDirectory: true)
    }

    var collectionsFolder: URL { folder.appendingPathComponent("Collections", isDirectory: true) }
    var keywordsFile: URL { folder.appendingPathComponent("Keywords.txt") }
    private var store: CollectionStore { CollectionStore(folder: collectionsFolder) }

    func reload() {
        collections = store.loadAll()
        let text = (try? String(contentsOf: keywordsFile, encoding: .utf8)) ?? ""
        keywords = KeywordLibrary(text: text)
    }

    func chooseFolderInteractively() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.prompt = "Use as Library"
        panel.message = "Choose a folder for collections and the keyword list. Existing files there are used as-is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bookmark = FolderAccess.grant(url) { UserDefaults.standard.set(bookmark, forKey: Keys.bookmark) }
        folder = url
        reload()
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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

    /// Keeps manual collections pointing at photos the app moved or renamed.
    func relocate(_ moves: [URL: URL]) {
        guard !moves.isEmpty else { return }
        for var collection in collections where collection.kind == .manual {
            if collection.relocate(moves) { save(collection) }
        }
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
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        addKeywords(KeywordLibrary(text: text).paths)
    }

    func exportKeywordsInteractively() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Keywords.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try keywords.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't export keywords: \(error.localizedDescription)"
        }
    }

    private func saveKeywords() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try keywords.text.write(to: keywordsFile, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't save the keyword list: \(error.localizedDescription)"
        }
    }
}

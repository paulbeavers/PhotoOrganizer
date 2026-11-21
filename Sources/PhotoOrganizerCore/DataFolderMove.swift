import Foundation

/// Moves the whole data folder (photos, collections, import records, settings, keywords) into
/// another, empty folder, then rewrites the paths stored inside it.
///
/// On the same volume every top-level item is renamed (instant, nothing is copied). Across
/// volumes every file is copied and verified like an import (SHA-256, re-read from disk), and the
/// originals are removed only after everything has been copied; a failure or cancel removes the
/// copies and leaves the original folder untouched.
public enum DataFolderMove {
    public struct Progress: Sendable, Equatable {
        public var filesDone = 0
        public var filesTotal = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var currentName = ""
        public init() {}
    }

    public enum MoveError: Error, LocalizedError, Equatable {
        case sameFolder, insideCurrent, notEmpty, cancelled

        public var errorDescription: String? {
            switch self {
            case .sameFolder: "That is already the data folder."
            case .insideCurrent: "The new location can't be inside the current data folder."
            case .notEmpty: "The new location must be an empty folder."
            case .cancelled: "The move was cancelled. Nothing was changed."
            }
        }
    }

    /// Whether `folder` has nothing in it but hidden files (e.g. .DS_Store): somewhere to move to.
    public static func isEmpty(_ folder: URL) -> Bool {
        visibleItems(in: folder).isEmpty
    }

    /// Whether `folder` already is a data folder (e.g. synced from another Mac).
    public static func isDataFolder(_ folder: URL) -> Bool {
        ["Settings.json", "Collections", "Imports", "Keywords.txt", ImportLayout.rootFolderName]
            .contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    public static func validate(from old: URL, to new: URL) throws {
        let oldPath = old.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let newPath = new.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        if oldPath == newPath { throw MoveError.sameFolder }
        if newPath.hasPrefix(oldPath + "/") { throw MoveError.insideCurrent }
        if !isEmpty(new) { throw MoveError.notEmpty }
    }

    /// Moves everything in `old` into `new` (which must be empty) and rewrites the stored paths.
    /// Returns the old → new path of each top-level item. `old` is removed if nothing is left in it.
    @discardableResult
    public static func run(from old: URL, to new: URL,
                           progress: @Sendable (Progress) -> Void = { _ in },
                           isCancelled: @Sendable () -> Bool = { false },
                           alwaysCopy: Bool = false) throws -> [URL: URL] {
        try validate(from: old, to: new)
        let fm = FileManager.default
        let items = visibleItems(in: old)
        var moved: [URL: URL] = [:]

        if sameVolume(old, new) && !alwaysCopy {   // (tests force the copy path)
            var state = Progress()
            state.filesTotal = items.count
            for item in items {
                let target = new.appendingPathComponent(item.lastPathComponent)
                state.currentName = item.lastPathComponent
                progress(state)
                try fm.moveItem(at: item, to: target)
                moved[item] = target
                state.filesDone += 1
            }
            progress(state)
        } else {
            let files = items.flatMap { item in allFiles(item).map { (url: $0, relative: relativePath($0, under: item)) } }
            var state = Progress()
            state.filesTotal = files.count
            state.bytesTotal = files.reduce(0) { $0 + Int64(fileSize($1.url)) }
            do {
                for (file, relative) in files {
                    if isCancelled() { throw MoveError.cancelled }
                    let target = new.appendingPathComponent(relative)
                    state.currentName = file.lastPathComponent
                    progress(state)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if isSymlink(file) {
                        try fm.copyItem(at: file, to: target)
                    } else {
                        try Importer.copyFile(from: file, to: target, verify: true) { bytes in
                            state.bytesDone += Int64(bytes)
                        }
                    }
                    state.filesDone += 1
                }
                // Empty folders (e.g. a day's Rejected) come along too.
                for item in items where isDirectory(item) {
                    for folder in [item] + allFolders(item) {
                        try fm.createDirectory(at: new.appendingPathComponent(relativePath(folder, under: item)),
                                               withIntermediateDirectories: true)
                    }
                }
            } catch {
                for item in items { try? fm.removeItem(at: new.appendingPathComponent(item.lastPathComponent)) }
                throw error
            }
            progress(state)
            for item in items {
                moved[item] = new.appendingPathComponent(item.lastPathComponent)
                try? fm.removeItem(at: item)
            }
        }
        if isEmpty(old) { try? fm.removeItem(at: old) }
        rewritePaths(in: new, from: old, to: new)
        return moved
    }

    // MARK: - Stored paths

    /// `path` with the `old` folder prefix replaced by `new` (portable "~/…" paths, any case);
    /// nil if it isn't inside `old`.
    public static func rebase(_ path: String, from old: String, to new: String) -> String? {
        let lowerPath = path.lowercased(), lowerOld = old.lowercased()
        if lowerPath == lowerOld { return new }
        guard lowerPath.hasPrefix(lowerOld + "/") else { return nil }
        return new + path.dropFirst(old.count)
    }

    /// Points everything the data folder stores at the new location: collections (items and
    /// folders), the import log, the import history, and the settings' sidebar folders and backup
    /// folder.
    public static func rewritePaths(in dataFolder: URL, from old: URL, to new: URL) {
        let oldPath = PortablePath.string(old), newPath = PortablePath.string(new)
        func fix(_ path: String) -> String { rebase(path, from: oldPath, to: newPath) ?? path }

        let collections = CollectionStore(folder: dataFolder.appendingPathComponent("Collections"))
        for var collection in collections.loadAll() {
            let items = collection.items.map(fix), folders = collection.folders.map(fix)
            guard items != collection.items || folders != collection.folders else { continue }
            collection.items = items
            collection.folders = folders
            try? collections.save(collection)
        }

        let log = ImportLog(dataFolder: dataFolder)
        for var session in log.loadAll() {
            let files = session.files.map(fix)
            guard files != session.files else { continue }
            session.files = files
            try? log.save(session)
        }

        let history = ImportHistory(dataFolder: dataFolder)
        let entries = history.load()
        let fixed = entries.mapValues(fix)
        if fixed != entries { try? history.record(fixed) }

        let settingsStore = SharedSettingsStore(folder: dataFolder)
        if var settings = settingsStore.load() {
            let original = settings
            settings.sidebarFolders = settings.sidebarFolders.map(fix)
            settings.importOptions.backupFolder = settings.importOptions.backupFolder.map(fix)
            if settings != original { try? settingsStore.save(settings) }
        }
    }

    // MARK: - Helpers

    /// "images/2026/…/a.jpg" for a file found under the top-level `item` ("images"). Compared with
    /// symlinks resolved: a folder listing may spell the path differently (/var vs /private/var).
    static func relativePath(_ url: URL, under item: URL) -> String {
        let base = item.resolvingSymlinksInPath().path
        // The folder resolved, not the file: a symlink file keeps its own name.
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
        guard path != base else { return item.lastPathComponent }
        guard path.hasPrefix(base + "/") else { return item.lastPathComponent + "/" + url.lastPathComponent }
        return item.lastPathComponent + "/" + path.dropFirst(base.count + 1)
    }

    static func visibleItems(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every file (and symlink) under `item`, or `item` itself if it is a file. Hidden files too.
    static func allFiles(_ item: URL) -> [URL] {
        guard isDirectory(item) else { return [item] }
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            if isSymlink(url) || !isDirectory(url) { files.append(url) }
        }
        return files
    }

    static func allFolders(_ item: URL) -> [URL] {
        var folders: [URL] = []
        let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if isDirectory(url) && !isSymlink(url) { folders.append(url) }
        }
        return folders
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}

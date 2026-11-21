import AppKit
import Observation
import PhotoOrganizerCore
import SwiftUI

/// Something to import from: a memory card / camera (a mounted external volume) or a folder.
struct ImportSource: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Specific files / folders chosen in the open panel; `nil` means "everything under `url`".
    var items: [URL]? = nil
    /// An external volume (card, camera, drive), which can be ejected afterwards.
    let isVolume: Bool
    /// Has a camera's DCIM folder (as far as the app can see before it has access).
    let hasDCIM: Bool
    var id: URL { url }
}

/// Thread-safe cancel flag shared with the background import.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func set() { lock.lock(); cancelled = true; lock.unlock() }
}

/// The import window and the import running behind it.
///
/// Photos are copied into `<data folder>/images/YYYY/yyyy-MM-dd/Imported/` (see `ImportLayout`), verified,
/// optionally backed up and tagged. The window closes as soon as an import starts; the grid shows
/// "Last Import" filling up, so culling can begin while files are still copying.
@MainActor
@Observable
final class ImportModel {
    let dataFolder: DataFolderModel
    let browser: BrowserModel

    var isPresented = false
    private(set) var volumes: [ImportSource] = []
    private(set) var source: ImportSource?
    private(set) var candidates: [ImportCandidate] = []
    private(set) var isScanning = false
    /// Candidates imported before (import history), or already at their destination.
    private(set) var alreadyImported: Set<URL> = []
    var selection: Set<URL> = []
    var errorMessage: String?

    private(set) var isImporting = false
    private(set) var progress = ImportProgress()
    /// One line about the last finished import, for the sidebar.
    /// How the most recent import went ("Imported 5 photos · card ejected"), shown on its entry.
    private(set) var lastSummary: String?
    /// The running import's entry under Imports.
    private(set) var runningSessionID: UUID?
    /// The entry `lastSummary` belongs to.
    private(set) var lastSessionID: UUID?

    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var scanCancel = CancelFlag()
    /// Top level of the import window's folder tree: the home folder's subfolders. Listing the
    /// home folder itself doesn't read Desktop / Documents / Downloads, so no privacy prompts appear
    /// until the user expands one of those.
    @ObservationIgnored private(set) lazy var homeFolders: [URL] = FolderScanner.subfolders(of: PortablePath.homeDirectory)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(dataFolder: DataFolderModel, browser: BrowserModel) {
        self.dataFolder = dataFolder
        self.browser = browser
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in self?.volumeMounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVolumes() }
        })
    }

    // MARK: Settings (in Settings.json)

    var settings: ImportSettings { dataFolder.settings.importOptions }

    func option<Value>(_ keyPath: WritableKeyPath<ImportSettings, Value>) -> Binding<Value> {
        Binding(get: { self.dataFolder.settings.importOptions[keyPath: keyPath] },
                set: { value in self.dataFolder.updateSettings { $0.importOptions[keyPath: keyPath] = value } })
    }

    var imagesRoot: URL { dataFolder.imagesURL }

    var backupFolderURL: URL? { settings.backupFolder.map(PortablePath.url) }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Backups"
        panel.message = "Choose where to keep a second copy of every import (for example a backup drive or NAS). The same year and day folders are created there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderAccess.rememberGrant(for: url)
        dataFolder.updateSettings {
            $0.importOptions.backupFolder = PortablePath.string(url)
            $0.importOptions.backupEnabled = true
        }
    }

    // MARK: Sources

    func present() {
        refreshVolumes()
        if source == nil, let card = volumes.first(where: \.hasDCIM) { select(card) }
        isPresented = true
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsRootFileSystem != true else { return nil }
            let external = values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
                || values?.volumeIsInternal == false
            guard external else { return nil }
            let hasDCIM = FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
            return ImportSource(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent,
                                isVolume: true, hasDCIM: hasDCIM)
        }
        .sorted { ($0.hasDCIM ? 0 : 1, $0.name) < ($1.hasDCIM ? 0 : 1, $1.name) }
        if let source, source.isVolume, !volumes.contains(where: { $0.url == source.url }) {
            self.source = nil
            candidates = []
        }
    }

    private func volumeMounted(_ url: URL?) {
        refreshVolumes()
        guard settings.showOnCardInsert, !isImporting, let url,
              let volume = volumes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              volume.hasDCIM else { return }
        select(volume)
        isPresented = true
        NSApp.activate()
    }

    func select(_ newSource: ImportSource) {
        // The sandboxed app may need the user's permission to read a card or drive.
        if !FolderAccess.canRead(newSource.url) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = newSource.url
            panel.prompt = "Allow"
            panel.message = "Photo Organizer needs your permission to read “\(newSource.name)”. Select it and click Allow."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            FolderAccess.rememberGrant(for: url)
        }
        source = newSource
        scan()
    }

    /// Opens the import window on folders / photos (e.g. a sidebar folder's "Import Photos from Here").
    func importFrom(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let isSingleFolder = urls.count == 1 && (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name = isSingleFolder ? FileManager.default.displayName(atPath: first.path)
            : urls.count == 1 ? first.lastPathComponent : "\(urls.count) items"
        source = ImportSource(url: isSingleFolder ? first : first.deletingLastPathComponent(), name: name,
                              items: isSingleFolder ? nil : urls, isVolume: false, hasDCIM: false)
        isPresented = true
        scan()
    }

    /// Reads the source's photos (with capture dates) and works out which were imported before.
    func scan() {
        guard let source else { return }
        scanTask?.cancel()
        scanCancel.set()             // stop a scan still walking a previous (perhaps huge) folder
        let cancel = CancelFlag()
        scanCancel = cancel
        let recursive = settings.includeSubfolders || source.isVolume
        isScanning = true
        candidates = []
        selection = []
        let dcim = source.url.appendingPathComponent("DCIM", isDirectory: true)
        let roots = source.items ?? [FileManager.default.fileExists(atPath: dcim.path) ? dcim : source.url]
        let historyStore = ImportHistory(dataFolder: dataFolder.url)
        let imagesRoot = imagesRoot
        let keepNames = !settings.renameFiles
        scanTask = Task {
            let (found, imported) = await Task.detached(priority: .userInitiated) { () -> ([ImportCandidate], Set<URL>) in
                let found = ImportScanner.candidates(from: roots, recursive: recursive, isCancelled: { cancel.isSet })
                let history = historyStore.load()
                let imported = found.filter { candidate in
                    if history[candidate.historyKey] != nil { return true }
                    // Copied before without the history (e.g. by hand): same name and size in its day folder.
                    guard keepNames else { return false }
                    let target = imagesRoot.appendingPathComponent(ImportLayout.destinationFolder(for: candidate.captureDate))
                        .appendingPathComponent(ImportLayout.noSpaces(candidate.name))
                    let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int
                    return size == candidate.size
                }
                return (found, Set(imported.map(\.url)))
            }.value
            guard !Task.isCancelled, !cancel.isSet, source == self.source else { return }
            candidates = found
            alreadyImported = imported
            selection = Set(found.map(\.url)).subtracting(imported)
            isScanning = false
        }
    }

    // MARK: Selection helpers

    /// Candidates grouped by capture day ("2026-11-19"), oldest first.
    var days: [(day: String, photos: [ImportCandidate])] {
        var order: [String] = []
        var groups: [String: [ImportCandidate]] = [:]
        for candidate in candidates {
            let day = String(ImportLayout.relativeFolder(for: candidate.captureDate).split(separator: "/").last ?? "")
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(candidate)
        }
        return order.map { ($0, groups[$0]!) }
    }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    func setDay(_ photos: [ImportCandidate], selected: Bool) {
        let urls = photos.map(\.url)
        if selected { selection.formUnion(urls) } else { selection.subtract(urls) }
    }

    func selectNewOnly() { selection = Set(candidates.map(\.url)).subtracting(alreadyImported) }
    func selectAll() { selection = Set(candidates.map(\.url)) }
    func selectNone() { selection = [] }

    /// The import as it would run now (with the current options and selection).
    var plan: ImportPlan {
        ImportPlan(candidates: candidates.filter { selection.contains($0.url) }, settings: settings)
    }

    // MARK: Running

    func startImport() {
        let plan = plan
        guard plan.fileCount > 0 else { return }
        var backupRoot: URL?
        if settings.backupEnabled {
            guard let backup = backupFolderURL else {
                errorMessage = "Choose a backup folder, or turn off the backup copy."
                return
            }
            guard FolderAccess.restoreAccess(to: backup) || FileManager.default.fileExists(atPath: backup.path) else {
                errorMessage = "The backup folder \(backup.path) isn't available. Connect the drive, choose another folder, or turn off the backup copy."
                return
            }
            backupRoot = backup
        }

        let options = Importer.Options(imagesRoot: imagesRoot, backupRoot: backupRoot, settings: settings)
        let flag = CancelFlag()
        cancelFlag = flag
        let ejectURL = (source?.isVolume == true && settings.ejectWhenDone) ? source?.url : nil
        let isFirstImport = !FileManager.default.fileExists(atPath: imagesRoot.path)
        let session = ImportSession(started: Date(), source: source?.name ?? "Import")
        isImporting = true
        progress = ImportProgress(filesTotal: plan.fileCount, bytesTotal: plan.byteCount)
        lastSummary = nil
        isPresented = false
        // The import is listed under Imports right away; its photos appear as they're copied.
        dataFolder.saveImportSession(session)
        runningSessionID = session.id
        lastSessionID = session.id
        browser.beginImport(session.id)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Importer.run(plan, options: options, isCancelled: { flag.isSet }) { url, progress in
                    Task { @MainActor in self.fileImported(url, progress: progress) }
                }
            }.value
            finish(result, session: session, ejectURL: ejectURL, isFirstImport: isFirstImport)
        }
    }

    func cancelImport() {
        cancelFlag.set()
    }

    private func fileImported(_ url: URL, progress: ImportProgress) {
        self.progress = progress
        if FileManager.default.fileExists(atPath: url.path) { browser.appendToImport(url) }
    }

    private func finish(_ result: ImportResult, session: ImportSession, ejectURL: URL?, isFirstImport: Bool) {
        isImporting = false
        runningSessionID = nil
        // Record what the import brought in; an import that copied nothing isn't kept.
        if result.imported.isEmpty {
            dataFolder.removeImportSession(session)
        } else {
            var session = session
            session.finished = Date()
            session.files = result.imported.map(PortablePath.string)
            dataFolder.saveImportSession(session)
        }
        do {
            try ImportHistory(dataFolder: dataFolder.url).record(result.history)
        } catch {
            errorMessage = "The photos were imported, but the import history couldn't be saved: \(error.localizedDescription)"
        }
        // The first import creates the images folder: put it in the sidebar once. If the user
        // removes it later, later imports leave the sidebar alone.
        if isFirstImport, FileManager.default.fileExists(atPath: imagesRoot.path), !browser.isRoot(imagesRoot) {
            browser.addRootFolders([imagesRoot])
        }
        browser.finishImport()

        let count = result.imported.count
        var summary = "Imported \(count) photo\(count == 1 ? "" : "s")"
        if result.wasCancelled { summary += " (cancelled)" }
        if !result.failures.isEmpty { summary += ", \(result.failures.count) failed" }
        lastSummary = summary

        if !result.failures.isEmpty {
            errorMessage = "\(summary).\n\n" + result.failures.prefix(12).joined(separator: "\n")
        } else if let ejectURL, !result.wasCancelled {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: ejectURL)
                lastSummary = summary + " · card ejected"
            } catch {
                lastSummary = summary + " · couldn't eject the card"
            }
        }
        if source != nil { scan() }  // refresh "already imported" if the window opens again
    }
}

import AppKit
import Observation
import PhotoOrganizerCore

enum PhotoSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case captureFolder = "Folder"
    case dateModified = "Date Modified"
    case rating = "Rating"
    case fileSize = "File Size"
    var id: String { rawValue }
}

/// What the grid is showing.
enum BrowseSource: Hashable {
    case folder(URL)
    case collection(UUID)
    /// One import (an entry under Collections → Imports); the running one fills in as files land.
    case importSession(UUID)
}

/// Files in one folder that share a base name (a RAW+JPEG pair), shown as one stack in the grid.
/// Opens the smart-collection editor (for a new collection or an existing one).
struct SmartEditorRequest: Identifiable {
    let id = UUID()
    var collection: PhotoCollection
    var isNew: Bool
}

struct StackInfo: Hashable {
    let key: String
    /// Position in the stack; 0 is the top (the RAW file, if there is one).
    let index: Int
    let count: Int
    let isExpanded: Bool
    /// Upper-case extensions of the members, top first, e.g. ["NEF", "JPG"].
    let extensions: [String]

    var isTop: Bool { index == 0 }
}

/// One cell in the grid.
struct GridEntry: Identifiable, Hashable {
    let photo: PhotoFile
    let stack: StackInfo?
    var id: URL { photo.url }
}

/// A request for a name, shown as a small sheet.
struct NamePrompt: Identifiable {
    enum Purpose {
        case newCollection(adding: [URL])
        case renameCollection(UUID)
        case newFolder(in: URL)
    }

    let id = UUID()
    let purpose: Purpose
    var initialName = ""

    var title: String {
        switch purpose {
        case .newCollection: "New Collection"
        case .renameCollection: "Rename Collection"
        case .newFolder: "New Folder"
        }
    }

    var actionTitle: String {
        switch purpose {
        case .renameCollection: "Rename"
        default: "Create"
        }
    }
}

/// Photos waiting for a rename or trash confirmation.
struct FileRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Unpicking (or rejecting) a pick would move the exports made from it in `Picked/` to the Trash:
/// shown for confirmation first.
struct CullCleanupRequest: Identifiable {
    let id = UUID()
    let files: [URL]
    let confirm: @MainActor () -> Void
}

/// A lazily expanded node in the sidebar folder tree.
final class FolderNode: Identifiable, @unchecked Sendable {  // only touched on the main thread
    let url: URL
    /// False for a sidebar folder this Mac hasn't been granted access to yet (sandbox), e.g. one
    /// that arrived in Settings.json from another Mac.
    let isAccessible: Bool
    private var loadedChildren: [FolderNode]?

    init(url: URL, isAccessible: Bool = true) {
        self.url = url
        self.isAccessible = isAccessible
    }

    var id: URL { url }
    var name: String { FileManager.default.displayName(atPath: url.path) }

    /// `nil` for leaf folders so the outline shows no disclosure triangle.
    var children: [FolderNode]? {
        guard isAccessible else { return nil }
        if loadedChildren == nil {
            loadedChildren = FolderScanner.subfolders(of: url).map { FolderNode(url: $0) }
        }
        return loadedChildren!.isEmpty ? nil : loadedChildren
    }
}

/// State for browsing: sources, photos and their tags, selection, filters, culling, file operations.
@MainActor
@Observable
final class BrowserModel {
    /// Local, per-Mac view state only. Everything else lives in `Settings.json` in the data folder.
    private enum Keys {
        static let lastFolder = "lastFolder"
    }

    let dataFolder: DataFolderModel

    private(set) var rootNodes: [FolderNode] = []
    private(set) var source: BrowseSource?
    private(set) var photos: [PhotoFile] = [] { didSet { refilter() } }
    private(set) var tags: [URL: PhotoTags] = [:] { didSet { refilter() } }
    /// EXIF and import dates for smart-collection rules; loaded only when the open collection's
    /// rules need them.
    private(set) var ruleInfo: [URL: RuleInfo] = [:] { didSet { refilter() } }
    /// Camera and lens of photos already read, so the smart-collection editor's lists open fast
    /// the second time.
    @ObservationIgnored private var gearCache: [URL: GearInfo] = [:]
    /// `photos` after filtering and sorting. Cached because many views read it.
    private(set) var visiblePhotos: [PhotoFile] = []
    /// What the grid shows: `visiblePhotos` with same-name files grouped into stacks.
    private(set) var gridItems: [GridEntry] = []
    /// The photos in the grid, in order: collapsed stacks contribute only their top photo. Keyboard
    /// navigation, selection ranges and review all walk this list.
    private(set) var displayedPhotos: [PhotoFile] = []
    /// Stacks the user opened (view state; not saved).
    var expandedStacks: Set<String> = [] { didSet { rebuildGrid() } }
    @ObservationIgnored private var stackMembers: [String: [URL]] = [:]
    private(set) var isLoading = false
    var errorMessage: String?

    var selection: Set<URL> = []
    private(set) var focused: URL?
    @ObservationIgnored private var anchor: URL?

    var criteria = SearchCriteria() { didSet { refilter() } }
    var sortOrder: PhotoSortOrder = .name { didSet { refilter() } }
    var sortAscending = true { didSet { refilter() } }
    var thumbnailSize: Double = 160
    /// Show the contents of all subfolders (stored in Settings.json).
    var includeSubfolders: Bool {
        get { dataFolder.settings.includeSubfolders }
        set {
            guard newValue != includeSubfolders else { return }
            dataFolder.updateSettings { $0.includeSubfolders = newValue }
            restartWatching()
            reload()
        }
    }
    /// Group same-name files into stacks (stored in Settings.json).
    var stacksEnabled: Bool {
        get { dataFolder.settings.stackSameName }
        set {
            dataFolder.updateSettings { $0.stackSameName = newValue }
            rebuildGrid()
        }
    }

    /// After rating/flagging a single photo, move to the next one (culling). Stored in Settings.json.
    var autoAdvance: Bool {
        get { dataFolder.settings.autoAdvance }
        set { dataFolder.updateSettings { $0.autoAdvance = newValue } }
    }

    // Presentation requests (sheets / confirmations), triggered from menus anywhere in the UI.
    var namePrompt: NamePrompt?
    var smartEditor: SmartEditorRequest?
    var renameRequest: FileRequest?
    var trashRequest: FileRequest?
    var cullCleanupRequest: CullCleanupRequest?

    /// Full-window review (loupe, or side-by-side compare of `compareURLs`).
    var isReviewing = false
    private(set) var compareURLs: [URL] = []

    @ObservationIgnored private let tagStore = TagStore()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileSystemWatcher?

    init(dataFolder: DataFolderModel) {
        self.dataFolder = dataFolder
        let defaults = UserDefaults.standard
        syncSidebarWithSettings()
        dataFolder.onMoved = { [weak self] old, new in self?.dataFolderMoved(from: old, to: new) }
        if let last = defaults.string(forKey: Keys.lastFolder), FileManager.default.fileExists(atPath: last) {
            open(.folder(URL(fileURLWithPath: last, isDirectory: true)))
        }
    }

    // MARK: - Derived

    var currentFolder: URL? {
        if case .folder(let url) = source { return url }
        return nil
    }

    var currentCollection: PhotoCollection? {
        if case .collection(let id) = source { return dataFolder.collection(id) }
        return nil
    }

    var title: String {
        switch source {
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        case .collection: currentCollection?.name ?? "Collection"
        case .importSession(let id): dataFolder.importSession(id).map { "Import · " + $0.started.formatted(date: .abbreviated, time: .shortened) } ?? "Import"
        case nil: "Photo Organizer"
        }
    }

    /// The open smart collection's rules, if a smart collection is open.
    var smartRules: SmartRules? {
        guard let collection = currentCollection, collection.kind == .smart else { return nil }
        return collection.effectiveRules
    }

    private func refilter() {
        let rules = smartRules
        let matching = photos.filter { photo in
            let photoTags = tags[photo.url] ?? .empty
            if let rules {
                let info = ruleInfo[photo.url]
                let facts = PhotoFacts(url: photo.url, tags: photoTags, captureDate: info?.captureDate,
                                       importDate: info?.importDate, camera: info?.camera, lens: info?.lens)
                guard rules.matches(facts) else { return false }
            }
            return criteria.matches(name: photo.name, tags: photoTags)
        }
        visiblePhotos = matching.sorted { sortAscending ? precedes($0, $1) : precedes($1, $0) }
        rebuildGrid()
    }

    // MARK: - Stacks

    static func stackKey(for url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path + "/" + url.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// Groups `visiblePhotos` into stacks. A stack sits where its first member sorts; its members
    /// are ordered RAW first, then by name.
    func rebuildGrid() {
        guard stacksEnabled else {
            stackMembers = [:]
            gridItems = visiblePhotos.map { GridEntry(photo: $0, stack: nil) }
            displayedPhotos = visiblePhotos
            return
        }
        var order: [String] = []
        var groups: [String: [PhotoFile]] = [:]
        for photo in visiblePhotos {
            let key = Self.stackKey(for: photo.url)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(photo)
        }
        var items: [GridEntry] = []
        var members: [String: [URL]] = [:]
        var topOfHidden: [URL: URL] = [:]
        for key in order {
            let group = groups[key]!.sorted { a, b in
                let rawA = Sidecar.isRaw(a.url), rawB = Sidecar.isRaw(b.url)
                return rawA != rawB ? rawA : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            guard group.count > 1 else {
                items.append(GridEntry(photo: group[0], stack: nil))
                continue
            }
            members[key] = group.map(\.url)
            let expanded = expandedStacks.contains(key)
            let extensions = group.map { $0.url.pathExtension.uppercased() }
            for (index, photo) in group.enumerated() {
                if expanded || index == 0 {
                    items.append(GridEntry(photo: photo, stack: StackInfo(key: key, index: index, count: group.count,
                                                                         isExpanded: expanded, extensions: extensions)))
                } else {
                    topOfHidden[photo.url] = group[0].url
                }
            }
        }
        stackMembers = members
        gridItems = items
        displayedPhotos = items.map(\.photo)

        // A selected photo that just got folded into a collapsed stack: select the stack instead.
        if !topOfHidden.isEmpty, !selection.isDisjoint(with: topOfHidden.keys) {
            selection = Set(selection.map { topOfHidden[$0] ?? $0 })
        }
        if let focused, let top = topOfHidden[focused] { self.focused = top }
    }

    func toggleStack(_ key: String) {
        if expandedStacks.contains(key) { expandedStacks.remove(key) } else { expandedStacks.insert(key) }
    }

    /// Opens or closes the stack the focused photo belongs to.
    func toggleFocusedStack() {
        guard let focused, stacksEnabled else { return }
        let key = Self.stackKey(for: focused)
        if stackMembers[key] != nil { toggleStack(key) }
    }

    func isInStack(_ url: URL) -> Bool { stackMembers[Self.stackKey(for: url)] != nil }

    func expandAllStacks() { expandedStacks = Set(stackMembers.keys) }
    func collapseAllStacks() { expandedStacks = [] }

    /// For file operations (move, copy, rename, trash, collections): a collapsed stack's top photo
    /// stands for the whole stack, so a RAW+JPEG pair is never split by accident.
    func includingStacks(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls {
            let key = Self.stackKey(for: url)
            let group = (stackMembers[key] != nil && !expandedStacks.contains(key) && stackMembers[key]?.first == url)
                ? stackMembers[key]! : [url]
            for member in group where seen.insert(member).inserted { result.append(member) }
        }
        return result
    }

    private func precedes(_ a: PhotoFile, _ b: PhotoFile) -> Bool {
        let byName = a.name.localizedStandardCompare(b.name) == .orderedAscending
        switch sortOrder {
        case .name: return byName
        case .captureFolder:
            let fa = a.url.deletingLastPathComponent().path, fb = b.url.deletingLastPathComponent().path
            return fa == fb ? byName : fa.localizedStandardCompare(fb) == .orderedAscending
        case .dateModified: return a.modified == b.modified ? byName : a.modified < b.modified
        case .fileSize: return a.fileSize == b.fileSize ? byName : a.fileSize < b.fileSize
        case .rating:
            let ra = tags[a.url]?.rating ?? 0, rb = tags[b.url]?.rating ?? 0
            return ra == rb ? byName : ra < rb
        }
    }

    /// Selected photos in display order.
    var selectedURLs: [URL] {
        displayedPhotos.map(\.url).filter(selection.contains)
    }

    /// The photo shown in the inspector preview and the loupe.
    var primaryPhoto: PhotoFile? {
        let url = focused.flatMap { selection.contains($0) ? $0 : nil } ?? selectedURLs.first
        return url.flatMap(photo(for:))
    }

    func photo(for url: URL) -> PhotoFile? {
        photos.first { $0.url == url }
    }

    /// The photos a context-menu action on `url` should affect.
    func targets(for url: URL) -> [URL] {
        selection.contains(url) ? selectedURLs : [url]
    }

    /// All keywords used by the photos currently loaded, for suggestions and the keyword panel.
    var loadedKeywords: [String] {
        Set(tags.values.flatMap(\.keywords)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Sources

    func open(_ newSource: BrowseSource) {
        guard newSource != source else { return }
        source = newSource
        if case .folder(let url) = newSource {
            UserDefaults.standard.set(url.path, forKey: Keys.lastFolder)
        }
        // A smart collection has its own rules; start it without leftover filter-bar filters.
        if currentCollection?.kind == .smart { criteria = SearchCriteria() }
        ruleInfo = [:]
        selection = []
        focused = nil
        anchor = nil
        isReviewing = false
        photos = []
        tags = [:]
        restartWatching()
        reload()
    }

    func open(_ folder: URL) {
        open(.folder(folder))
    }

    /// Re-scans the source and re-reads tags. Keeps existing values on screen while loading, so it is
    /// cheap to call whenever files change on disk (e.g. Photoshop saved a file).
    func reload() {
        guard let source else { return }
        loadTask?.cancel()
        isLoading = true
        let store = tagStore
        let scan = scanner(for: source)
        loadTask = Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) { try scan() }.value
                guard !Task.isCancelled, source == self.source else { return }
                photos = found
                errorMessage = nil
                let present = Set(found.map(\.url))
                selection.formIntersection(present)
                if let f = focused, !present.contains(f) { focused = nil }

                var loadedTags = tags.filter { present.contains($0.key) }
                for chunk in found.chunked(into: 250) {
                    let loaded = await Task.detached(priority: .utility) {
                        chunk.map { ($0.url, store.tags(for: $0.url)) }
                    }.value
                    guard !Task.isCancelled else { return }
                    for (url, t) in loaded { loadedTags[url] = t }
                    if loadedTags != tags { tags = loadedTags }
                }
                // Smart-collection rules on camera / lens / dates: read what they need.
                if let rules = smartRules, rules.needsMetadata || rules.usesImportDate {
                    let readEXIF = rules.needsMetadata
                    let importDates = ImportLog.importDates(dataFolder.importSessions)
                    var loadedInfo = ruleInfo
                    for chunk in found.chunked(into: 250) {
                        let loaded = await Task.detached(priority: .utility) {
                            chunk.map { photo in (photo.url, RuleInfo.read(photo.url, exif: readEXIF, importDates: importDates)) }
                        }.value
                        guard !Task.isCancelled else { return }
                        for (url, info) in loaded { loadedInfo[url] = info }
                        ruleInfo = loadedInfo
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                photos = []
                errorMessage = "Couldn't read \(title): \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func scanner(for source: BrowseSource) -> @Sendable () throws -> [PhotoFile] {
        switch source {
        case .folder(let url):
            let recursive = includeSubfolders
            return { try FolderScanner.photos(in: url, recursive: recursive) }
        case .collection(let id):
            guard let collection = dataFolder.collection(id) else { return { [] } }
            switch collection.kind {
            case .manual:
                let items = collection.itemURLs
                return { FolderScanner.photoFiles(items) }
            case .smart:
                let scope = smartScope
                return {
                    var seen = Set<URL>()
                    return scope.flatMap { (try? FolderScanner.photos(in: $0, recursive: true)) ?? [] }
                        .filter { seen.insert($0.url).inserted }
                }
            }
        case .importSession(let id):
            let urls = id == liveImportID ? liveImportURLs : dataFolder.importSession(id)?.fileURLs ?? []
            return { FolderScanner.photoFiles(urls) }
        }
    }

    private func restartWatching() {
        watcher = nil
        let paths: [URL]
        var recursive = true
        switch source {
        case .folder(let url):
            paths = [url]
            recursive = includeSubfolders
        case .importSession:
            return  // fixed sets of files
        case .collection:
            guard let collection = currentCollection else { return }
            switch collection.kind {
            case .smart: paths = smartScope
            case .manual: paths = Array(Set(collection.itemURLs.map { $0.deletingLastPathComponent() }))
            }
        case nil:
            return
        }
        let watched = Set(paths.map { FileSystemWatcher.canonical($0.path) })
        let watchesSubfolders = recursive
        watcher = FileSystemWatcher(paths: paths) { [weak self] changed in
            let relevant = watchesSubfolders || changed.contains { watched.contains(FileSystemWatcher.canonical($0)) }
            guard relevant else { return }
            Task { @MainActor in self?.reload() }
        }
    }

    func refresh() {
        dataFolder.reload()
        syncSidebarWithSettings(force: true)
        reload()
    }

    /// While the data folder is being moved, changes would be lost (the copy may already be made):
    /// refuse them with a message.
    func blockedByDataFolderMove() -> Bool {
        guard dataFolder.moveProgress != nil else { return false }
        errorMessage = "The data folder is being moved. Try again when the move has finished."
        return true
    }

    /// After the data folder moved: the sidebar follows, and a folder that moved along reopens at
    /// its new place.
    private func dataFolderMoved(from old: URL, to new: URL) {
        syncSidebarWithSettings(force: true)
        if case .folder(let folder) = source,
           let path = DataFolderMove.rebase(PortablePath.string(folder), from: PortablePath.string(old),
                                             to: PortablePath.string(new)) {
            open(.folder(PortablePath.url(path)))
        } else {
            restartWatching()
            reload()
        }
    }

    // MARK: - Running import

    /// The import being copied right now, and its files so far (in import order).
    private(set) var liveImportID: UUID?
    private(set) var liveImportURLs: [URL] = []
    @ObservationIgnored private var liveImportReloadPending = false

    private var isShowingLiveImport: Bool {
        guard let liveImportID else { return false }
        return source == .importSession(liveImportID)
    }

    /// Shows the new import (empty) as it starts; photos appear as they're copied.
    func beginImport(_ id: UUID) {
        liveImportID = id
        liveImportURLs = []
        // Select the new entry once the sidebar has added it: selecting a List row in the same
        // update that inserts it leaves a stale copy of the row drawn behind (SwiftUI List bug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.liveImportID == id else { return }
                self.open(.importSession(id))
            }
        }
    }

    func appendToImport(_ url: URL) {
        liveImportURLs.append(url)
        // Refresh the grid at most a couple of times a second while copying.
        guard isShowingLiveImport, !liveImportReloadPending else { return }
        liveImportReloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.liveImportReloadPending = false
                if self?.isShowingLiveImport == true { self?.reload() }
            }
        }
    }

    /// The import is saved in the import log by now; show it from there.
    func finishImport() {
        let wasShowing = isShowingLiveImport
        let id = liveImportID
        liveImportID = nil
        liveImportURLs = []
        refreshSidebar()
        if wasShowing {
            if let id, dataFolder.importSession(id) != nil { reload() } else { close() }
        }
    }

    /// Shows nothing (after the open collection or import is removed).
    func close() {
        source = nil
        photos = []
        tags = [:]
        selection = []
        focused = nil
        criteria = SearchCriteria()
    }

    // MARK: - Sidebar folders

    /// Rebuilds the sidebar from `Settings.json`. Called at launch and whenever the settings change
    /// (including changes synced from another Mac).
    func syncSidebarWithSettings(force: Bool = false) {
        // One entry per folder: macOS paths ignore case, so "…/Images" and "…/images" are the same.
        let saved = dataFolder.settings.sidebarFolders
        var seen = Set<String>()
        let unique = saved.filter { seen.insert($0.lowercased()).inserted }
        if unique.count != saved.count {
            dataFolder.updateSettings { $0.sidebarFolders = unique }
        }
        let urls = dataFolder.settings.sidebarFolderURLs
        guard force || urls != rootNodes.map(\.url) else { return }
        rootNodes = urls.map { FolderNode(url: $0, isAccessible: FolderAccess.restoreAccess(to: $0)) }
    }

    func addRootFoldersInteractively() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add to Sidebar"
        guard panel.runModal() == .OK else { return }
        addRootFolders(panel.urls)
        if let first = panel.urls.first { open(first) }
    }

    func addRootFolders(_ urls: [URL]) {
        for url in urls { FolderAccess.rememberGrant(for: url) }
        dataFolder.updateSettings { settings in
            for url in urls {
                let path = PortablePath.string(url)
                if !settings.sidebarFolders.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                    settings.sidebarFolders.append(path)
                }
            }
        }
        syncSidebarWithSettings(force: true)
    }

    func removeRootFolder(_ url: URL) {
        let path = PortablePath.string(url)
        dataFolder.updateSettings { $0.sidebarFolders.removeAll { $0 == path } }
        syncSidebarWithSettings()
    }

    /// Compares paths, not URLs, and ignores case like macOS does (`…/images`, `…/images/` and
    /// `…/Images` are the same folder).
    func isRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return rootNodes.contains { $0.url.standardizedFileURL.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    func isAccessible(_ url: URL) -> Bool {
        rootNodes.first { $0.url == url }?.isAccessible ?? true
    }

    /// Asks the user to grant this Mac access to a sidebar folder (needed in the sandboxed app for
    /// folders outside ~/Pictures that came from another Mac's Settings.json).
    func grantAccessInteractively(to url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url
        panel.prompt = "Grant Access"
        panel.message = "Photo Organizer needs your permission to open “\(url.lastPathComponent)” on this Mac. Select the folder and click Grant Access."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        FolderAccess.rememberGrant(for: chosen)
        if chosen.standardizedFileURL != url.standardizedFileURL {
            // The user picked a different folder (e.g. it lives elsewhere on this Mac): use that one.
            let old = PortablePath.string(url), new = PortablePath.string(chosen)
            dataFolder.updateSettings { settings in
                settings.sidebarFolders = settings.sidebarFolders.map { $0 == old ? new : $0 }
            }
        }
        syncSidebarWithSettings(force: true)
        open(chosen)
    }

    // MARK: - Selection

    func click(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            anchor = url
        } else if modifiers.contains(.shift), let anchor {
            let visible = displayedPhotos.map(\.url)
            if let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: url) {
                selection = Set(visible[min(a, b)...max(a, b)])
            }
        } else {
            selection = [url]
            anchor = url
        }
        focused = url
    }

    func select(_ url: URL) {
        selection = [url]
        anchor = url
        focused = url
    }

    func moveSelection(by offset: Int, extend: Bool = false) {
        let visible = displayedPhotos.map(\.url)
        guard !visible.isEmpty else { return }
        let next = focused.flatMap { visible.firstIndex(of: $0) }
            .map { min(max($0 + offset, 0), visible.count - 1) } ?? 0
        let url = visible[next]
        if extend {
            selection.insert(url)
            focused = url
        } else {
            select(url)
        }
    }

    func selectAll() {
        selection = Set(displayedPhotos.map(\.url))
    }

    func clearSelection() {
        selection = []
    }

    // MARK: - Review (loupe / compare)

    func startReview() {
        let selected = selectedURLs
        compareURLs = (2...4).contains(selected.count) ? selected : []
        if selected.isEmpty, let first = displayedPhotos.first { select(first.url) }
        guard !displayedPhotos.isEmpty else { return }
        isReviewing = true
    }

    func endReview() {
        isReviewing = false
        compareURLs = []
    }

    // MARK: - Tagging (written to XMP sidecars)

    func setRating(_ rating: Int, for urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs, advance: urls == nil) { $0.rating = rating }
    }

    func pick(_ urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs, advance: urls == nil) { $0.pick() }
    }

    func reject(_ urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs, advance: urls == nil) { $0.reject() }
    }

    func unflag(_ urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs, advance: urls == nil) { $0.unflag() }
    }

    func setLabel(_ label: ColorLabel?, for urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs) { $0.label = label }
    }

    /// Applies `label`, or clears it if every target already has it (like Bridge).
    func toggleLabel(_ label: ColorLabel, for urls: [URL]? = nil) {
        let targets = urls ?? selectedURLs
        let allHaveIt = targets.allSatisfy { tags[$0]?.label == label }
        setLabel(allHaveIt ? nil : label, for: targets)
    }

    func addKeywords(_ text: String, to urls: [URL]? = nil) {
        let keywords = PhotoTags.parseKeywords(text)
        guard !keywords.isEmpty else { return }
        updateTags(urls ?? selectedURLs) { $0.keywords.append(contentsOf: keywords) }
    }

    func removeKeyword(_ keyword: String, from urls: [URL]? = nil) {
        updateTags(urls ?? selectedURLs) { tags in
            tags.keywords.removeAll { $0.caseInsensitiveCompare(keyword) == .orderedSame }
        }
    }

    /// Adds `keyword` to all targets, or removes it if they all have it already.
    func toggleKeyword(_ keyword: String, for urls: [URL]? = nil) {
        let targets = urls ?? selectedURLs
        if keywordCount(keyword, in: targets) == targets.count {
            removeKeyword(keyword, from: targets)
        } else {
            updateTags(targets) { $0.keywords.append(keyword) }
        }
    }

    func keywordCount(_ keyword: String, in urls: [URL]) -> Int {
        urls.filter { url in
            tags[url]?.keywords.contains { $0.caseInsensitiveCompare(keyword) == .orderedSame } ?? false
        }.count
    }

    func setField(_ field: IPTCField, to value: String, for urls: [URL]) {
        updateTags(urls) { $0[field] = value }
    }

    private func updateTags(_ urls: [URL], advance: Bool = false, cleanupConfirmed: Bool = false,
                            _ change: @escaping (inout PhotoTags) -> Void) {
        guard !urls.isEmpty, !blockedByDataFolderMove() else { return }
        // Photos in a day's Imported / Picked / Rejected move to the folder for their new flag.
        let cull = cullChanges(urls, change)
        let extras = cull.filter { $0.before == .picked && $0.after != .picked }.flatMap(\.exports)
        if !extras.isEmpty && !cleanupConfirmed {
            cullCleanupRequest = CullCleanupRequest(files: extras) { [weak self] in
                self?.updateTags(urls, advance: advance, cleanupConfirmed: true, change)
            }
            return
        }
        let visibleBefore = displayedPhotos.map(\.url)
        let focusIndex = focused.flatMap { visibleBefore.firstIndex(of: $0) }

        var updated = tags
        var failures: [String] = []
        for url in urls {
            do {
                updated[url] = try tagStore.update(url, change)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        tags = updated
        var moves: [URL: URL] = [:]
        for change in cull where change.before != change.after {
            let moved = CullFolders.move(change.originals, to: change.after)
            moves.merge(moved.completed) { $1 }
            failures += moved.failures
        }
        if !extras.isEmpty {
            failures += FileOperations.trash(extras).failures
        }
        applyMoves(moves)
        if !failures.isEmpty {
            errorMessage = "Couldn't save tags.\n" + failures.joined(separator: "\n")
        }

        // Culling: if the focused photo was filtered out by the change, keep the same position;
        // otherwise optionally advance to the next photo.
        let visible = displayedPhotos.map(\.url)
        if let focused, !visible.contains(focused), let focusIndex, !visible.isEmpty {
            select(visible[min(focusIndex, visible.count - 1)])
        } else if advance, autoAdvance, urls.count == 1, compareURLs.isEmpty {
            moveSelection(by: 1)
        }
    }

    private typealias CullChange = (originals: [URL], exports: [URL], before: CullFolders.State, after: CullFolders.State)

    /// For photos in a day's Imported / Picked / Rejected folder: each pair's cull state before and
    /// after `change`, and the exports made from it (photos no import brought in).
    private func cullChanges(_ urls: [URL], _ change: (inout PhotoTags) -> Void) -> [CullChange] {
        let changing = Set(urls)
        let imported = Set(ImportLog.importDates(dataFolder.importSessions).keys)
        let isOriginal = { (url: URL) in imported.contains(PortablePath.string(url).lowercased()) }
        var seen = Set<String>()
        var result: [CullChange] = []
        for url in urls where CullFolders.dayFolder(of: url) != nil {
            let key = url.deletingPathExtension().path.lowercased()
            guard seen.insert(key).inserted else { continue }
            let group = CullFolders.group(of: url, isOriginal: isOriginal)
            let current = group.originals.map { tags[$0] ?? tagStore.tags(for: $0) }
            let changed = zip(group.originals, current).map { member, memberTags in
                var copy = memberTags
                if changing.contains(member) { change(&copy) }
                return copy
            }
            result.append((group.originals, group.exports, CullFolders.State(group: current), CullFolders.State(group: changed)))
        }
        return result
    }

    /// After photos moved (e.g. into Picked): collections and the import list follow them, and the
    /// grid shows them at their new place, or drops them if this folder no longer contains them.
    /// (The folder watcher reloads afterwards.)
    private func applyMoves(_ moves: [URL: URL]) {
        guard !moves.isEmpty else { return }
        dataFolder.relocate(moves)
        if liveImportID != nil { liveImportURLs = liveImportURLs.map { moves[$0] ?? $0 } }
        func stillShown(_ url: URL) -> Bool {
            guard case .folder(let folder) = source else { return true }
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            let shown = folder.standardizedFileURL.path
            return parent == shown || (includeSubfolders && parent.hasPrefix(shown + "/"))
        }
        var movedTags = tags
        var movedInfo = ruleInfo
        for (old, new) in moves {
            if let t = movedTags.removeValue(forKey: old) { movedTags[new] = t }
            if let info = movedInfo.removeValue(forKey: old) { movedInfo[new] = info }
        }
        photos = photos.compactMap { photo in
            guard let new = moves[photo.url] else { return photo }
            return stillShown(new) ? PhotoFile(url: new, fileSize: photo.fileSize, modified: photo.modified,
                                               contentType: photo.contentType) : nil
        }
        tags = movedTags
        ruleInfo = movedInfo
        selection = Set(selection.map { moves[$0] ?? $0 })
        focused = focused.map { moves[$0] ?? $0 }
        anchor = anchor.map { moves[$0] ?? $0 }
    }

    // MARK: - Collections

    func submitNamePrompt(_ prompt: NamePrompt, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch prompt.purpose {
        case .newCollection(let urls): createCollection(named: name, adding: urls)
        case .renameCollection(let id): renameCollection(id, to: name)
        case .newFolder(let parent): createFolder(named: name, in: parent)
        }
    }

    func createCollection(named name: String, adding urls: [URL] = []) {
        var collection = PhotoCollection(name: name, kind: .manual)
        collection.add(urls)
        dataFolder.save(collection)
    }

    /// A new smart collection. Smart collections search every photo in the data folder.
    func newSmartCollection(rules: SmartRules = SmartRules(rules: [SmartRule(field: .keyword)])) {
        let collection = PhotoCollection(name: "", kind: .smart, rules: rules)
        smartEditor = SmartEditorRequest(collection: collection, isNew: true)
    }

    /// The filter bar's current search as the starting rules of a new smart collection.
    func saveSearchAsSmartCollection() {
        newSmartCollection(rules: SmartRules(criteria: criteria))
    }

    /// Where smart collections look: the data folder and every sidebar folder this Mac can read,
    /// without folders that are inside another one (they'd be scanned twice).
    var smartScope: [URL] {
        let candidates = [dataFolder.url] + rootNodes.filter(\.isAccessible).map(\.url)
        let paths = candidates.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        func inside(_ child: URL, _ parent: URL) -> Bool {
            child.path.lowercased().hasPrefix(parent.path.lowercased() + "/")
        }
        var scope: [URL] = []
        for (index, url) in paths.enumerated() {
            let covered = paths.enumerated().contains { other in
                other.offset != index && (inside(url, other.element)
                    || (other.offset < index && other.element.path.caseInsensitiveCompare(url.path) == .orderedSame))
            }
            if !covered { scope.append(candidates[index]) }
        }
        return scope
    }

    /// Every camera, lens and keyword used by the photos in the data folder and sidebar folders (keywords also from
    /// Keywords.txt), for the smart-collection editor's menus.
    func smartRuleChoices() async -> RuleChoices {
        let scope = smartScope
        let known = gearCache
        let store = tagStore
        let (gear, photoKeywords) = await Task.detached(priority: .userInitiated) { () -> ([URL: GearInfo], Set<String>) in
            var gear: [URL: GearInfo] = [:]
            var keywords = Set<String>()
            let photos = scope.flatMap { (try? FolderScanner.photos(in: $0, recursive: true)) ?? [] }
            for photo in photos {
                if let cached = known[photo.url] {
                    gear[photo.url] = cached
                } else {
                    let info = MetadataReader.ruleInfo(of: photo.url)
                    gear[photo.url] = GearInfo(camera: info.camera, lens: info.lens)
                }
                keywords.formUnion(store.tags(for: photo.url).keywords)   // sidecars change: always read
            }
            return (gear, keywords)
        }.value
        gearCache.merge(gear) { $1 }
        func sorted(_ values: some Sequence<String>) -> [String] {
            Set(values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return RuleChoices(cameras: sorted(gear.values.compactMap(\.camera)),
                           lenses: sorted(gear.values.compactMap(\.lens)),
                           keywords: RuleChoices.unique(photoKeywords.union(dataFolder.keywords.paths)))
    }

    func editSmartCollection(_ id: UUID) {
        guard var collection = dataFolder.collection(id), collection.kind == .smart else { return }
        collection.rules = collection.effectiveRules   // convert an older saved search once
        smartEditor = SmartEditorRequest(collection: collection, isNew: false)
    }

    func saveSmartCollection(_ collection: PhotoCollection) {
        var collection = collection
        collection.criteria = SearchCriteria()          // rules replace the old saved search
        guard dataFolder.save(collection) else { return }
        if source == .collection(collection.id) {
            ruleInfo = [:]
            restartWatching()
            reload()
        } else {
            criteria = SearchCriteria()
            open(.collection(collection.id))
        }
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard var collection = dataFolder.collection(id), !name.isEmpty else { return }
        collection.name = name
        dataFolder.save(collection)
    }

    func deleteCollection(_ id: UUID) {
        guard let collection = dataFolder.collection(id) else { return }
        dataFolder.delete(collection)
        if source == .collection(id) {
            source = nil
            photos = []
            tags = [:]
            criteria = SearchCriteria()
        }
    }

    func removeFromCurrentCollection(_ urls: [URL]) {
        guard let collection = currentCollection, collection.kind == .manual else { return }
        dataFolder.remove(urls, from: collection.id)
        reload()
    }

    // MARK: - File operations

    // Copy / move / trash take a collapsed stack whole (`includingStacks`).

    func copy(_ urls: [URL], to destination: URL) {
        let urls = includingStacks(urls)
        runFileOperation("copy") { FileOperations.copy(urls, to: destination) }
    }

    func move(_ urls: [URL], to destination: URL) {
        let urls = includingStacks(urls)
        runFileOperation("move", relocates: true) { FileOperations.move(urls, to: destination) }
    }

    func moveToTrash(_ urls: [URL]) {
        let urls = includingStacks(urls)
        runFileOperation("move to Trash") { FileOperations.trash(urls) }
    }

    func rename(_ items: [RenamePlan.Item]) {
        runFileOperation("rename", relocates: true, reselect: true) { FileOperations.rename(items) }
    }

    /// Asks for a destination folder, then copies or moves.
    func transferInteractively(_ urls: [URL], move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move" : "Copy"
        panel.message = "\(move ? "Move" : "Copy") \(urls.count) photo\(urls.count == 1 ? "" : "s") and their sidecars to:"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        _ = destination.startAccessingSecurityScopedResource()
        if move { self.move(urls, to: destination) } else { copy(urls, to: destination) }
    }

    func createFolder(named name: String, in parent: URL) {
        do {
            let url = try FileOperations.createFolder(named: name, in: parent)
            refreshSidebar()
            open(url)
        } catch {
            errorMessage = "Couldn't create folder: \(error.localizedDescription)"
        }
    }

    /// Photos dropped onto a sidebar folder: move them (or copy with ⌥). Folders dropped from Finder
    /// are added to the sidebar instead.
    func handleDrop(_ urls: [URL], onto folder: URL?, copy: Bool) -> Bool {
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !directories.isEmpty {
            addRootFolders(directories)
        }
        var files = urls.filter { !directories.contains($0) }
        guard let folder, !files.isEmpty else { return !directories.isEmpty }
        // Dragging one photo of a multi-selection drags the whole selection; collapsed stacks
        // travel whole.
        if files.count == 1, selection.contains(files[0]) { files = selectedURLs }
        files = includingStacks(files)
        if copy { self.copy(files, to: folder) } else { move(files, to: folder) }
        return true
    }

    private func refreshSidebar() {
        syncSidebarWithSettings(force: true)
    }

    private func runFileOperation(_ verb: String, relocates: Bool = false, reselect: Bool = false,
                                  _ operation: @escaping @Sendable () -> FileOperationResult) {
        guard !blockedByDataFolderMove() else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { operation() }.value
            if relocates { dataFolder.relocate(result.completed) }
            if reselect {
                selection = Set(result.completed.values)
                focused = focused.flatMap { result.completed[$0] }
            }
            if result.hasFailures {
                let failed = result.failures.count
                errorMessage = "Couldn't \(verb) \(failed) item\(failed == 1 ? "" : "s").\n"
                    + result.failures.prefix(10).joined(separator: "\n")
            }
            refreshSidebar()
            reload()
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

/// What smart-collection rules need beyond tags: EXIF and the import date.
struct RuleInfo: Sendable {
    var captureDate: Date?
    var camera: String?
    var lens: String?
    var importDate: Date?

    static func read(_ url: URL, exif: Bool, importDates: [String: Date]) -> RuleInfo {
        var info = RuleInfo()
        if exif {
            let read = MetadataReader.ruleInfo(of: url)
            info.captureDate = read.date
            info.camera = read.camera
            info.lens = read.lens
        }
        // Imported by the app: the import's date; otherwise when the file was added to its folder.
        info.importDate = importDates[PortablePath.string(url).lowercased()] ?? ImportLog.dateAdded(url)
        return info
    }
}

struct GearInfo: Sendable {
    var camera: String?
    var lens: String?
}

/// What the smart-collection editor offers in its menus: the cameras, lenses and keywords in the
/// data folder.
struct RuleChoices: Equatable, Sendable {
    var cameras: [String] = []
    var lenses: [String] = []
    /// Keywords, each once (ignoring case), alphabetical.
    var keywords: [String] = []

    static func unique(_ keywords: some Sequence<String>) -> [String] {
        var all: [String: String] = [:]   // lower-cased → as written (first spelling wins)
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, all[trimmed.lowercased()] == nil { all[trimmed.lowercased()] = trimmed }
        }
        return all.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

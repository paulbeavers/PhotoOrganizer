import CryptoKit
import Foundation

// MARK: - Settings

/// Which files of a shoot to import.
public enum ImportFileTypes: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, rawOnly, nonRawOnly

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .all: "RAW + JPEG"
        case .rawOnly: "RAW only"
        case .nonRawOnly: "JPEG only"
        }
    }

    func includes(_ url: URL) -> Bool {
        switch self {
        case .all: true
        case .rawOnly: Sidecar.isRaw(url)
        case .nonRawOnly: !Sidecar.isRaw(url)
        }
    }
}

/// Import options, saved in Settings.json so they sync with the data folder.
public struct ImportSettings: Codable, Equatable, Sendable {
    /// Rename with `nameTemplate`; otherwise keep the camera's names (spaces still become "_").
    public var renameFiles = false
    public var nameTemplate = "{date:yyyyMMdd}_{n:4}"
    public var fileTypes: ImportFileTypes = .all
    /// Written into every imported photo's sidecar (creator / copyright only when it has none).
    public var creator = ""
    public var copyright = ""
    /// Comma-separated; "Places > Iceland" makes a hierarchical keyword.
    public var keywords = ""
    /// Re-read every copy from disk and compare its SHA-256 with the source.
    public var verifyCopies = true
    /// Also copy everything to `backupFolder` (same year/day layout).
    public var backupEnabled = false
    /// Portable path (see `PortablePath`).
    public var backupFolder: String?
    public var ejectWhenDone = true
    /// Open the import window when a memory card or camera is connected.
    public var showOnCardInsert = true
    /// When importing from a folder, include its subfolders.
    public var includeSubfolders = true

    public init() {}


    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImportSettings()
        renameFiles = try c.decodeIfPresent(Bool.self, forKey: .renameFiles) ?? d.renameFiles
        nameTemplate = try c.decodeIfPresent(String.self, forKey: .nameTemplate) ?? d.nameTemplate
        fileTypes = (try? c.decodeIfPresent(ImportFileTypes.self, forKey: .fileTypes)) ?? d.fileTypes
        creator = try c.decodeIfPresent(String.self, forKey: .creator) ?? d.creator
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright) ?? d.copyright
        keywords = try c.decodeIfPresent(String.self, forKey: .keywords) ?? d.keywords
        verifyCopies = try c.decodeIfPresent(Bool.self, forKey: .verifyCopies) ?? d.verifyCopies
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? d.backupEnabled
        backupFolder = try c.decodeIfPresent(String.self, forKey: .backupFolder)
        ejectWhenDone = try c.decodeIfPresent(Bool.self, forKey: .ejectWhenDone) ?? d.ejectWhenDone
        showOnCardInsert = try c.decodeIfPresent(Bool.self, forKey: .showOnCardInsert) ?? d.showOnCardInsert
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? d.includeSubfolders
    }

    var tagsToApply: (creator: String, copyright: String, keywords: [String]) {
        (creator.trimmingCharacters(in: .whitespaces), copyright.trimmingCharacters(in: .whitespaces),
         PhotoTags.parseKeywords(keywords))
    }
}

// MARK: - Layout

/// Where imported photos go: `<data folder>/images/YYYY/yyyy-MM-dd/Imported/<name>` (see `CullFolders`).
public enum ImportLayout {
    public static let rootFolderName = "images"

    /// "2026/2026-11-19" (zero-padded month and day) for the capture date, in local time like the
    /// camera's own clock.
    public static func relativeFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: date)
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(year)/\(formatter.string(from: date))"
    }

    /// "2026/2026-11-19/Imported": where an import puts the photos of that day.
    public static func destinationFolder(for date: Date) -> String {
        relativeFolder(for: date) + "/" + CullFolders.imported
    }

    /// File names never contain spaces: every run of whitespace becomes one "_".
    public static func noSpaces(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }
}

// MARK: - Scanning a source

/// A photo found on a card or in a folder.
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int
    public let captureDate: Date
    public let camera: String?
    public var id: URL { url }
    public var isRaw: Bool { Sidecar.isRaw(url) }
    public var name: String { url.lastPathComponent }

    public init(url: URL, size: Int, captureDate: Date, camera: String? = nil) {
        self.url = url
        self.size = size
        self.captureDate = captureDate
        self.camera = camera
    }

    /// Identifies "the same shot" across imports: original name, size and capture time.
    public var historyKey: String {
        "\(url.lastPathComponent.lowercased())|\(size)|\(Int(captureDate.timeIntervalSince1970))"
    }
}

public enum ImportScanner {
    /// Every photo under `source` (subfolders included, editor folders such as NKSC_PARAM skipped),
    /// with its capture date and camera, oldest first. Reads metadata in parallel.
    public static func candidates(in source: URL) -> [ImportCandidate] {
        candidates(from: [source])
    }

    /// Photos from a mix of folders and individual files. Folders include their subfolders unless
    /// `recursive` is false. Stops early (returning what it has) when `isCancelled` turns true.
    public static func candidates(from sources: [URL], recursive: Bool = true,
                                  isCancelled: @Sendable () -> Bool = { false }) -> [ImportCandidate] {
        var seen = Set<URL>()
        let files = sources.flatMap { source -> [PhotoFile] in
            let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isFolder ? ((try? FolderScanner.photos(in: source, recursive: recursive, isCancelled: isCancelled)) ?? [])
                            : FolderScanner.photoFiles([source])
        }
        .filter { seen.insert($0.url).inserted }
        let results = CandidateSlots(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if isCancelled() { return }
            let file = files[index]
            let info = MetadataReader.importInfo(of: file.url)
            results.set(index, ImportCandidate(url: file.url, size: file.fileSize,
                                               captureDate: info.date ?? file.modified, camera: info.camera))
        }
        return results.all.sorted {
            $0.captureDate == $1.captureDate ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                             : $0.captureDate < $1.captureDate
        }
    }
}

/// Results written from `concurrentPerform`, one slot per file, guarded by a lock.
private final class CandidateSlots: @unchecked Sendable {
    private var slots: [ImportCandidate?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ candidate: ImportCandidate) {
        lock.lock(); slots[index] = candidate; lock.unlock()
    }

    var all: [ImportCandidate] {
        lock.lock(); defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}

// MARK: - History (what has been imported before)

/// `ImportHistory.json` in the data folder: shot key → where it was imported to. Lets the import
/// window grey out photos already imported, on any Mac that shares the data folder.
public struct ImportHistory: Sendable {
    public let fileURL: URL

    public init(dataFolder: URL) {
        fileURL = dataFolder.appendingPathComponent("ImportHistory.json")
    }

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }

    /// Merges `entries` into the file (re-reading it first, in case another Mac added some).
    public func record(_ entries: [String: String]) throws {
        guard !entries.isEmpty else { return }
        var all = load()
        all.merge(entries) { _, new in new }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Plan

/// What an import will do: which files, into which day folder, under which base name. Files that
/// share a base name in one source folder (a RAW+JPEG pair) stay together under one new name.
public struct ImportPlan: Sendable {
    public struct Group: Sendable, Identifiable {
        public let members: [ImportCandidate]
        /// "2026/2026-11-19"
        public let folder: String
        /// Base name without extension; never contains spaces.
        public let baseName: String
        public var id: URL { members[0].url }
    }

    public let groups: [Group]
    public var fileCount: Int { groups.reduce(0) { $0 + $1.members.count } }
    public var byteCount: Int { groups.reduce(0) { $0 + $1.members.reduce(0) { $0 + $1.size } } }

    public init(candidates: [ImportCandidate], settings: ImportSettings, startNumber: Int = 1) {
        let included = candidates.filter { settings.fileTypes.includes($0.url) }
        var order: [String] = []
        var buckets: [String: [ImportCandidate]] = [:]
        for candidate in included {
            let key = candidate.url.deletingLastPathComponent().path + "/"
                + candidate.url.deletingPathExtension().lastPathComponent.lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(candidate)
        }
        let sorted = order.map { buckets[$0]! }.sorted { a, b in
            let da = a.map(\.captureDate).min()!, db = b.map(\.captureDate).min()!
            return da == db ? a[0].name.localizedStandardCompare(b[0].name) == .orderedAscending : da < db
        }
        groups = sorted.enumerated().map { index, members in
            let date = members.map(\.captureDate).min()!
            let folder = ImportLayout.destinationFolder(for: date)
            let day = ImportLayout.relativeFolder(for: date)
            let original = members[0].url.deletingPathExtension().lastPathComponent
            var base = original
            if settings.renameFiles {
                let context = RenamePlan.Context(name: original, number: startNumber + index, date: date,
                                                 camera: members.first { $0.camera != nil }?.camera ?? "",
                                                 folder: String(day.split(separator: "/").last ?? ""))
                base = RenamePlan.expand(settings.nameTemplate, context)
            }
            base = ImportLayout.noSpaces(RenamePlan.sanitize(base))
            if base.isEmpty { base = ImportLayout.noSpaces(original) }
            return Group(members: members, folder: folder, baseName: base)
        }
    }
}

// MARK: - Running an import

public struct ImportProgress: Sendable {
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone = 0
    public var bytesTotal = 0
    public var currentName = ""

    public init(filesDone: Int = 0, filesTotal: Int = 0, bytesDone: Int = 0, bytesTotal: Int = 0, currentName: String = "") {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentName = currentName
    }
}

public struct ImportResult: Sendable {
    /// Imported photos at their new location (primary destination), in order.
    public var imported: [URL] = []
    public var failures: [String] = []
    /// Entries to add to `ImportHistory`.
    public var history: [String: String] = [:]
    public var wasCancelled = false
}

public enum ImportError: Error, LocalizedError {
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let name): "the copy of \(name) didn't match the original (it was removed)"
        }
    }
}

public enum Importer {
    public struct Options: Sendable {
        public let imagesRoot: URL
        public let backupRoot: URL?
        public let settings: ImportSettings

        public init(imagesRoot: URL, backupRoot: URL?, settings: ImportSettings) {
            self.imagesRoot = imagesRoot
            self.backupRoot = backupRoot
            self.settings = settings
        }
    }

    /// Copies every group of the plan, verifying each copy if asked, then copies the result to the
    /// backup folder and writes the import tags. Checks `isCancelled` between files; reports each
    /// imported photo (and the progress) through `onImported`.
    public static func run(_ plan: ImportPlan, options: Options,
                           isCancelled: @Sendable () -> Bool = { false },
                           onImported: @Sendable (URL, ImportProgress) -> Void = { _, _ in }) -> ImportResult {
        let fm = FileManager.default
        let verify = options.settings.verifyCopies
        let tags = options.settings.tagsToApply
        var result = ImportResult()
        var progress = ImportProgress(filesTotal: plan.fileCount, bytesTotal: plan.byteCount)

        for group in plan.groups {
            if isCancelled() { result.wasCancelled = true; break }
            let folder = options.imagesRoot.appendingPathComponent(group.folder, isDirectory: true)
            let backupFolder = options.backupRoot?.appendingPathComponent(group.folder, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if let backupFolder { try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true) }
            } catch {
                result.failures.append("\(group.folder): \(error.localizedDescription)")
                continue
            }
            let extensions = group.members.map(\.url.pathExtension)
            let base = freeBaseName(group.baseName, in: [folder] + (backupFolder.map { [$0] } ?? []), extensions: extensions)

            for member in group.members {
                if isCancelled() { result.wasCancelled = true; break }
                progress.currentName = member.name
                let target = folder.appendingPathComponent(base).appendingPathExtension(member.url.pathExtension)
                do {
                    try copyFile(from: member.url, to: target, verify: verify) { progress.bytesDone += $0 }
                    copyCompanions(of: member.url, to: target)
                    if !tags.creator.isEmpty || !tags.copyright.isEmpty || !tags.keywords.isEmpty {
                        try TagStore().update(target) { photoTags in
                            if photoTags[.creator].isEmpty, !tags.creator.isEmpty { photoTags[.creator] = tags.creator }
                            if photoTags[.copyright].isEmpty, !tags.copyright.isEmpty { photoTags[.copyright] = tags.copyright }
                            photoTags.keywords.append(contentsOf: tags.keywords)
                        }
                    }
                    if let backupFolder {
                        let backupTarget = backupFolder.appendingPathComponent(target.lastPathComponent)
                        try copyFile(from: target, to: backupTarget, verify: verify) { _ in }
                        copyCompanions(of: target, to: backupTarget)
                    }
                    result.imported.append(target)
                    result.history[member.historyKey] = PortablePath.string(target)
                } catch {
                    result.failures.append("\(member.name): \(error.localizedDescription)")
                }
                progress.filesDone += 1
                onImported(target, progress)
            }
        }
        return result
    }

    /// A base name free in every folder for every extension, its sidecars and editor files.
    static func freeBaseName(_ base: String, in folders: [URL], extensions: [String]) -> String {
        func isFree(_ candidate: String) -> Bool {
            folders.allSatisfy { folder in
                FileOperations.availableBaseName(candidate, in: folder, extensions: extensions + ["xmp"],
                                                 companionExtensions: extensions) == candidate
            }
        }
        if isFree(base) { return base }
        var n = 2
        while !isFree("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Copies a photo's sidecar and editor files next to its copy (e.g. when importing from a
    /// folder of photos that were already rated or edited).
    static func copyCompanions(of source: URL, to target: URL) {
        let fm = FileManager.default
        for companion in CompanionFileType.existing(for: source) {
            let destination = companion.type.url(for: target)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: companion.url, to: destination)
        }
        // A RAW's <base>.xmp, or a non-RAW photo's sidecar from before per-file sidecars.
        let sidecar = Sidecar.isRaw(source) ? Sidecar.sharedURL(for: source) : Sidecar.legacyURL(for: source)
        if let sidecar, fm.fileExists(atPath: sidecar.path) {
            let destination = Sidecar.url(for: target)
            if !fm.fileExists(atPath: destination.path) { try? fm.copyItem(at: sidecar, to: destination) }
        }
    }

    /// Copies a file in 4 MB chunks, hashing as it goes; with `verify`, re-reads the copy from disk
    /// (bypassing the cache) and compares checksums. A failed or mismatched copy is removed.
    public static func copyFile(from source: URL, to target: URL, verify: Bool,
                                onBytes: (Int) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: target)
            var hasher = SHA256()
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                onBytes(chunk.count)
            }
            try output.synchronize()
            try output.close()
            let expected = hasher.finalize()
            if let modified = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            }
            if verify, try sha256(of: target, bypassingCache: true) != expected {
                throw ImportError.verificationFailed(source.lastPathComponent)
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    static func sha256(of url: URL, bypassingCache: Bool) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassingCache { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }  // read what's on disk
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }
}

import Foundation

/// An editor's per-photo settings file, which must travel with the photo it belongs to.
///
/// Unlike the shared XMP sidecar (`IMG_1.xmp`, one per base name), these are named after the photo's
/// *full* file name, so each file of a RAW+JPEG pair has its own.
public struct CompanionFileType: Sendable, Hashable {
    public let editor: String
    /// Subfolder of the photo's folder that holds the file, or `nil` for "next to the photo".
    public let subfolder: String?
    /// Appended to the photo's full file name, e.g. ".nksc" → "DSC_0001.NEF.nksc".
    public let suffix: String

    public static let nxStudio = CompanionFileType(editor: "NX Studio", subfolder: "NKSC_PARAM", suffix: ".nksc")
    public static let rawTherapee = CompanionFileType(editor: "RawTherapee", subfolder: nil, suffix: ".pp3")
    public static let dxoPhotoLab = CompanionFileType(editor: "DxO PhotoLab", subfolder: nil, suffix: ".dop")
    /// Per-file XMP sidecars: this app's for non-RAW photos (`DSC_1.JPG.xmp`, see `Sidecar`), and
    /// darktable's / digiKam's for any photo.
    public static let xmpSidecar = CompanionFileType(editor: "XMP sidecar", subfolder: nil, suffix: ".xmp")

    /// Every companion type the app keeps with photos. Add new editors here.
    public static let all: [CompanionFileType] = [.xmpSidecar, .nxStudio, .rawTherapee, .dxoPhotoLab]

    /// Where this type's file for `photo` lives (whether or not it exists).
    public func url(for photo: URL) -> URL {
        var folder = photo.deletingLastPathComponent()
        if let subfolder { folder.appendPathComponent(subfolder, isDirectory: true) }
        return folder.appendingPathComponent(photo.lastPathComponent + suffix)
    }

    /// The companion files that exist for `photo`.
    public static func existing(for photo: URL) -> [(type: CompanionFileType, url: URL)] {
        all.map { ($0, $0.url(for: photo)) }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    /// Editor folders that hold companion files; hidden from the sidebar folder tree.
    public static var folderNames: Set<String> { Set(all.compactMap(\.subfolder)) }
}

/// Result of a batch file operation: what moved where, and what failed.
public struct FileOperationResult: Sendable {
    /// Original photo URL -> new photo URL (for trash, the URL in the Trash).
    public var completed: [URL: URL] = [:]
    public var failures: [String] = []

    public var hasFailures: Bool { !failures.isEmpty }
}

/// Copy / move / rename / trash for photos, keeping XMP sidecars with their photos.
///
/// Files are processed in *groups*: all selected files in one folder that share a base name
/// (e.g. `DSC_1.NEF` + `DSC_1.JPG`) travel together with their shared sidecar. If only part of a
/// pair is processed, the sidecar is copied rather than moved so the file left behind keeps its tags.
///
/// Each photo's editor settings files (`CompanionFileType`, e.g. NX Studio's
/// `NKSC_PARAM/<file>.nksc`) are moved, copied, renamed and trashed with that photo.
public enum FileOperations {
    struct Group {
        let folder: URL
        let baseName: String
        let members: [URL]

        /// The shared `<base>.xmp`: the RAW file's sidecar (and, from before per-file sidecars, a
        /// non-RAW photo's when no RAW file shares the name). Non-RAW photos' own `<file>.xmp`
        /// sidecars are companion files.
        var sidecar: URL { folder.appendingPathComponent(baseName).appendingPathExtension("xmp") }
        var hasSidecar: Bool { usesSharedSidecar && FileManager.default.fileExists(atPath: sidecar.path) }

        private var allWithBaseName: [URL] { FileOperations.photos(in: folder, baseName: baseName) }

        /// Whether any member reads `<base>.xmp`: RAW members always; non-RAW ones only when no RAW
        /// file has this base name. (Moving just the JPEG of a pair leaves the RAW's sidecar alone.)
        var usesSharedSidecar: Bool {
            members.contains(where: Sidecar.isRaw) || !allWithBaseName.contains(where: Sidecar.isRaw)
        }

        /// Photos outside the operation that also read `<base>.xmp` (so it must be copied, not moved).
        var remainingSiblings: [URL] {
            let memberPaths = Set(members.map(\.standardizedFileURL.path))
            let all = allWithBaseName
            let others = all.filter { !memberPaths.contains($0.standardizedFileURL.path) }
            let anyRaw = (members + others).contains(where: Sidecar.isRaw)
            return others.filter { anyRaw ? Sidecar.isRaw($0) : true }
        }
    }

    static func groups(for urls: [URL]) -> [Group] {
        var order: [String] = []
        var buckets: [String: (folder: URL, base: String, members: [URL])] = [:]
        for url in urls {
            let folder = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let key = folder.standardizedFileURL.path + "/" + base.lowercased()
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (folder, base, [])
            }
            buckets[key]!.members.append(url)
        }
        return order.map { Group(folder: buckets[$0]!.folder, baseName: buckets[$0]!.base, members: buckets[$0]!.members) }
    }

    static func photos(in folder: URL, baseName: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
            url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
                && FolderScanner.isPhoto(url: url, type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        }
    }

    // MARK: - Copy / move

    public static func copy(_ urls: [URL], to destination: URL) -> FileOperationResult {
        transfer(urls, to: destination, move: false)
    }

    public static func move(_ urls: [URL], to destination: URL) -> FileOperationResult {
        transfer(urls, to: destination, move: true)
    }

    private static func transfer(_ urls: [URL], to destination: URL, move: Bool) -> FileOperationResult {
        let fm = FileManager.default
        var result = FileOperationResult()
        for group in groups(for: urls) {
            if move, group.folder.standardizedFileURL == destination.standardizedFileURL { continue }
            // Choose a base name that is free in the destination for every member and the sidecar.
            let base = availableBaseName(group.baseName, in: destination,
                                         extensions: group.members.map(\.pathExtension) + ["xmp"],
                                         companionExtensions: group.members.map(\.pathExtension))
            var transferred: [URL] = []
            for source in group.members {
                let target = destination.appendingPathComponent(base).appendingPathExtension(source.pathExtension)
                // Read before moving: afterwards the photo is gone from `source`.
                let companions = CompanionFileType.existing(for: source)
                do {
                    if move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
                    result.completed[source] = target
                    transferred.append(source)
                } catch {
                    result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                for companion in companions {
                    let companionTarget = companion.type.url(for: target)
                    do {
                        try fm.createDirectory(at: companionTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if move { try fm.moveItem(at: companion.url, to: companionTarget) } else { try fm.copyItem(at: companion.url, to: companionTarget) }
                    } catch {
                        result.failures.append("\(companion.url.lastPathComponent) (\(companion.type.editor) settings): \(error.localizedDescription)")
                    }
                }
            }
            guard !transferred.isEmpty, group.hasSidecar else { continue }
            let sidecarTarget = destination.appendingPathComponent(base).appendingPathExtension("xmp")
            do {
                let everythingMoved = move && transferred.count == group.members.count && group.remainingSiblings.isEmpty
                if everythingMoved {
                    try fm.moveItem(at: group.sidecar, to: sidecarTarget)
                } else {
                    try fm.copyItem(at: group.sidecar, to: sidecarTarget)
                }
            } catch {
                result.failures.append("\(group.sidecar.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// `base`, or `base-2`, `base-3`... so that no `<base>.<ext>` already exists in `folder`, and no
    /// companion file (e.g. a leftover `NKSC_PARAM/<base>.NEF.nksc`) is in the way either.
    static func availableBaseName(_ base: String, in folder: URL, extensions: [String],
                                  companionExtensions: [String] = []) -> String {
        let fm = FileManager.default
        func isFree(_ candidate: String) -> Bool {
            let photos = extensions.map { folder.appendingPathComponent(candidate).appendingPathExtension($0) }
            let companions = companionExtensions.flatMap { ext in
                CompanionFileType.all.map { $0.url(for: folder.appendingPathComponent(candidate).appendingPathExtension(ext)) }
            }
            return (photos + companions).allSatisfy { !fm.fileExists(atPath: $0.path) }
        }
        if isFree(base) { return base }
        var n = 2
        while !isFree("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Trash

    public static func trash(_ urls: [URL]) -> FileOperationResult {
        let fm = FileManager.default
        var result = FileOperationResult()
        for group in groups(for: urls) {
            var allTrashed = true
            for url in group.members {
                let companions = CompanionFileType.existing(for: url)
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                    result.completed[url] = trashed as URL? ?? url
                    for companion in companions {
                        try? fm.trashItem(at: companion.url, resultingItemURL: nil)
                    }
                } catch {
                    allTrashed = false
                    result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if allTrashed, group.hasSidecar, group.remainingSiblings.isEmpty {
                try? fm.trashItem(at: group.sidecar, resultingItemURL: nil)
            }
        }
        return result
    }

    // MARK: - Rename

    /// Renames photos to new base names (extensions are kept). Every member of a group gets the same
    /// new base name, and the sidecar follows. Uses a two-phase rename so names can be swapped.
    public static func rename(_ plan: [RenamePlan.Item]) -> FileOperationResult {
        let fm = FileManager.default
        var result = FileOperationResult()

        /// `owner`: for an editor settings file, the photo it belongs to. It is only renamed if that
        /// photo is, so a failed photo rename never separates the photo from its edits.
        struct Step { let from: URL; let temp: URL; let to: URL; let photo: URL?; let copySidecar: Bool; var owner: URL? = nil }
        var steps: [Step] = []
        for item in plan where item.newBaseName != item.group.baseName {
            let group = item.group
            for member in group.members {
                let target = group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension(member.pathExtension)
                steps.append(Step(from: member, temp: temporaryURL(near: member), to: target, photo: member, copySidecar: false))
                for companion in CompanionFileType.existing(for: member) {
                    let companionTarget = companion.type.url(for: target)
                    steps.append(Step(from: companion.url, temp: temporaryURL(near: companion.url), to: companionTarget,
                                      photo: nil, copySidecar: false, owner: member))
                }
            }
            if group.hasSidecar {
                let target = group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension("xmp")
                let shared = !group.remainingSiblings.isEmpty
                steps.append(Step(from: group.sidecar, temp: temporaryURL(near: group.sidecar), to: target, photo: nil, copySidecar: shared))
            }
        }

        // Phase 1: move everything out of the way (shared sidecars are copied, not moved).
        var staged: [Step] = []
        var failedPhotos = Set<URL>()
        for step in steps {
            if let owner = step.owner, failedPhotos.contains(owner) { continue }  // leave edits with their photo
            do {
                if step.copySidecar { try fm.copyItem(at: step.from, to: step.temp) } else { try fm.moveItem(at: step.from, to: step.temp) }
                staged.append(step)
            } catch {
                if let photo = step.photo { failedPhotos.insert(photo) }
                result.failures.append("\(step.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Phase 2: move into final names.
        for step in staged {
            if let owner = step.owner, failedPhotos.contains(owner) {
                try? fm.moveItem(at: step.temp, to: step.from)  // the photo stayed put, so its edits do too
                continue
            }
            do {
                guard !fm.fileExists(atPath: step.to.path) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: step.to.path])
                }
                try fm.moveItem(at: step.temp, to: step.to)
                if let photo = step.photo { result.completed[photo] = step.to }
            } catch {
                // Put it back where it came from.
                if step.copySidecar { try? fm.removeItem(at: step.temp) } else { try? fm.moveItem(at: step.temp, to: step.from) }
                if let photo = step.photo { failedPhotos.insert(photo) }
                result.failures.append("\(step.from.lastPathComponent) → \(step.to.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func temporaryURL(near url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)-\(url.lastPathComponent)")
    }

    // MARK: - Folders

    public static func createFolder(named name: String, in parent: URL) throws -> URL {
        let clean = RenamePlan.sanitize(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = parent.appendingPathComponent(clean, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

/// Builds new names for a batch rename from a template.
///
/// Tokens: `{name}` original base name · `{n}` sequence number (`{n:4}` pads to 4 digits) ·
/// `{date}` capture date as yyyy-MM-dd (`{date:yyyyMMdd}` for a custom format) · `{time}` HHmmss ·
/// `{camera}` camera model · `{folder}` parent folder name. Anything else is literal text.
public struct RenamePlan: Sendable {
    public struct Item: Sendable, Identifiable {
        let group: FileOperations.Group
        public let newBaseName: String
        public var id: String { group.folder.path + "/" + group.baseName }
        public var oldNames: [String] { group.members.map(\.lastPathComponent) }
        public var newNames: [String] { group.members.map { newBaseName + "." + $0.pathExtension } }
        public var isUnchanged: Bool { newBaseName == group.baseName }
    }

    public let items: [Item]
    /// Human-readable problems that block the rename (duplicates, collisions, empty names).
    public let problems: [String]

    public init(urls: [URL], template: String, startNumber: Int = 1,
                captureDate: (URL) -> Date? = { MetadataReader.captureDate(of: $0) },
                cameraModel: (URL) -> String? = { MetadataReader.cameraModel(of: $0) }) {
        let groups = FileOperations.groups(for: urls)
        var items: [Item] = []
        for (index, group) in groups.enumerated() {
            let first = group.members[0]
            let context = Context(name: group.baseName, number: startNumber + index,
                                  date: captureDate(first) ?? Self.modificationDate(first),
                                  camera: cameraModel(first) ?? "",
                                  folder: group.folder.lastPathComponent)
            items.append(Item(group: group, newBaseName: Self.sanitize(Self.expand(template, context))))
        }
        self.items = items
        self.problems = Self.validate(items)
    }

    struct Context {
        let name: String
        let number: Int
        let date: Date
        let camera: String
        let folder: String
    }

    static func expand(_ template: String, _ context: Context) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = rest[rest.index(after: open)..<close]
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : nil
            switch parts.first?.lowercased() ?? "" {
            case "name": output += context.name
            case "n", "seq":
                let width = argument.flatMap(Int.init) ?? 1
                let digits = String(context.number)
                output += String(repeating: "0", count: max(0, width - digits.count)) + digits
            case "date": output += format(context.date, argument ?? "yyyy-MM-dd")
            case "time": output += format(context.date, argument ?? "HHmmss")
            case "camera": output += context.camera
            case "folder": output += context.folder
            default: output += "{\(token)}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return output + rest
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    /// Removes characters that are illegal or troublesome in file names.
    public static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private static func validate(_ items: [Item]) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        if items.contains(where: { $0.newBaseName.isEmpty }) {
            problems.append("The template produces an empty name.")
        }
        // Names must be unique within each folder.
        var seen: [String: Int] = [:]
        for item in items { seen[item.group.folder.path + "/" + item.newBaseName.lowercased(), default: 0] += 1 }
        let duplicates = seen.filter { $0.value > 1 }.count
        if duplicates > 0 {
            problems.append("\(duplicates) name\(duplicates == 1 ? " is" : "s are") used more than once. Add {n} to the template.")
        }
        // New names must not collide with files that aren't being renamed.
        let renamedPaths = Set(items.flatMap { item in
            item.group.members.map(\.path) + [item.group.sidecar.path]
                + item.group.members.flatMap { member in CompanionFileType.existing(for: member).map(\.url.path) }
        }.map { $0.lowercased() })
        for item in items where !item.isUnchanged {
            let targets = item.group.members.map(\.pathExtension) + (item.group.hasSidecar ? ["xmp"] : [])
            for ext in targets {
                let path = item.group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension(ext).path
                if fm.fileExists(atPath: path), !renamedPaths.contains(path.lowercased()) {
                    problems.append("\(item.newBaseName).\(ext) already exists.")
                }
            }
            for member in item.group.members {
                let newPhoto = item.group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension(member.pathExtension)
                for companion in CompanionFileType.existing(for: member) {
                    let target = companion.type.url(for: newPhoto)
                    if fm.fileExists(atPath: target.path), !renamedPaths.contains(target.path.lowercased()) {
                        problems.append("\(companion.type.editor) settings \(target.lastPathComponent) already exist.")
                    }
                }
            }
        }
        return problems
    }
}

import Foundation

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
public enum FileOperations {
    struct Group {
        let folder: URL
        let baseName: String
        let members: [URL]

        var sidecar: URL { folder.appendingPathComponent(baseName).appendingPathExtension("xmp") }
        var hasSidecar: Bool { FileManager.default.fileExists(atPath: sidecar.path) }

        /// Photos in the same folder sharing this base name that are *not* part of the operation.
        var remainingSiblings: [URL] {
            let memberPaths = Set(members.map(\.standardizedFileURL.path))
            return FileOperations.photos(in: folder, baseName: baseName)
                .filter { !memberPaths.contains($0.standardizedFileURL.path) }
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
                                         extensions: group.members.map(\.pathExtension) + ["xmp"])
            var transferred: [URL] = []
            for source in group.members {
                let target = destination.appendingPathComponent(base).appendingPathExtension(source.pathExtension)
                do {
                    if move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
                    result.completed[source] = target
                    transferred.append(source)
                } catch {
                    result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
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

    /// `base`, or `base-2`, `base-3`... so that no `<base>.<ext>` already exists in `folder`.
    static func availableBaseName(_ base: String, in folder: URL, extensions: [String]) -> String {
        let fm = FileManager.default
        func isFree(_ candidate: String) -> Bool {
            extensions.allSatisfy { ext in
                !fm.fileExists(atPath: folder.appendingPathComponent(candidate).appendingPathExtension(ext).path)
            }
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
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                    result.completed[url] = trashed as URL? ?? url
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

        struct Step { let from: URL; let temp: URL; let to: URL; let photo: URL?; let copySidecar: Bool }
        var steps: [Step] = []
        for item in plan where item.newBaseName != item.group.baseName {
            let group = item.group
            for member in group.members {
                let target = group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension(member.pathExtension)
                steps.append(Step(from: member, temp: temporaryURL(near: member), to: target, photo: member, copySidecar: false))
            }
            if group.hasSidecar {
                let target = group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension("xmp")
                let shared = !group.remainingSiblings.isEmpty
                steps.append(Step(from: group.sidecar, temp: temporaryURL(near: group.sidecar), to: target, photo: nil, copySidecar: shared))
            }
        }

        // Phase 1: move everything out of the way (shared sidecars are copied, not moved).
        var staged: [Step] = []
        for step in steps {
            do {
                if step.copySidecar { try fm.copyItem(at: step.from, to: step.temp) } else { try fm.moveItem(at: step.from, to: step.temp) }
                staged.append(step)
            } catch {
                result.failures.append("\(step.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Phase 2: move into final names.
        for step in staged {
            do {
                guard !fm.fileExists(atPath: step.to.path) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: step.to.path])
                }
                try fm.moveItem(at: step.temp, to: step.to)
                if let photo = step.photo { result.completed[photo] = step.to }
            } catch {
                // Put it back where it came from.
                if step.copySidecar { try? fm.removeItem(at: step.temp) } else { try? fm.moveItem(at: step.temp, to: step.from) }
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
        }.map { $0.lowercased() })
        for item in items where !item.isUnchanged {
            let targets = item.group.members.map(\.pathExtension) + (item.group.hasSidecar ? ["xmp"] : [])
            for ext in targets {
                let path = item.group.folder.appendingPathComponent(item.newBaseName).appendingPathExtension(ext).path
                if fm.fileExists(atPath: path), !renamedPaths.contains(path.lowercased()) {
                    problems.append("\(item.newBaseName).\(ext) already exists.")
                }
            }
        }
        return problems
    }
}

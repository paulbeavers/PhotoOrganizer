import Foundation

/// The cull layout of an import day:
///
/// ```
/// images/2026/2026-11-19/
///   Imported/   photos not culled yet (where an import puts them)
///   Picked/     the picks, with their sidecars and editor files, plus exports made there
///   Rejected/   the rejects
/// ```
///
/// Picking, rejecting or unflagging a photo in one of these folders moves it (with its XMP
/// sidecar and NX Studio / RawTherapee / DxO edit files, via `FileOperations.move`) into the folder
/// for its new state, so an editor pointed at `Picked/` sees only the keepers, as real files.
/// The sidecar's flag stays the record. A RAW+JPEG pair moves together: it counts as picked if
/// either file is. Exports (photos made in `Picked/` that no import brought in) never move.
public enum CullFolders {
    public static let imported = "Imported"
    public static let picked = "Picked"
    public static let rejected = "Rejected"

    public enum State: Sendable, Equatable {
        case picked, rejected, none

        public init(_ tags: PhotoTags) {
            self = tags.isPicked ? .picked : tags.isRejected ? .rejected : .none
        }

        /// A pair's state: picked if any file is, else rejected if any is.
        public init(group tags: [PhotoTags]) {
            let states = tags.map(State.init)
            self = states.contains(.picked) ? .picked : states.contains(.rejected) ? .rejected : .none
        }

        public var folderName: String {
            switch self {
            case .picked: CullFolders.picked
            case .rejected: CullFolders.rejected
            case .none: CullFolders.imported
            }
        }
    }

    /// For a photo in `<day>/Imported|Picked|Rejected/`, the day folder; nil anywhere else.
    public static func dayFolder(of photo: URL) -> URL? {
        let parent = photo.deletingLastPathComponent()
        return [imported, picked, rejected].contains(parent.lastPathComponent) ? parent.deletingLastPathComponent() : nil
    }

    /// The photos with this photo's base name in its folder, split into originals (which move
    /// together) and exports (which stay). If none of them is a known original, they all move.
    public static func group(of photo: URL, isOriginal: (URL) -> Bool) -> (originals: [URL], exports: [URL]) {
        var all = FileOperations.photos(in: photo.deletingLastPathComponent(),
                                        baseName: photo.deletingPathExtension().lastPathComponent)
        if all.isEmpty { all = [photo] }
        let originals = all.filter(isOriginal)
        if originals.isEmpty { return (all, []) }
        return (originals, all.filter { !isOriginal($0) })
    }

    /// Moves photos into their day's folder for `state` (with sidecars and editor files). Photos
    /// already there, or outside a day folder, stay. A name already taken there gets "-2" etc.
    public static func move(_ photos: [URL], to state: State) -> FileOperationResult {
        var result = FileOperationResult()
        let byDay = Dictionary(grouping: photos.filter { dayFolder(of: $0) != nil }) { dayFolder(of: $0)! }
        for (day, members) in byDay {
            let target = day.appendingPathComponent(state.folderName, isDirectory: true)
            let toMove = members.filter { $0.deletingLastPathComponent().lastPathComponent != state.folderName }
            guard !toMove.isEmpty else { continue }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                result.failures.append("\(state.folderName): \(error.localizedDescription)")
                continue
            }
            let moved = FileOperations.move(toMove, to: target)
            result.completed.merge(moved.completed) { $1 }
            result.failures += moved.failures
        }
        return result
    }
}

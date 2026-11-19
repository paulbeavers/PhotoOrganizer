import Foundation
import PhotoOrganizerCore

/// Keeps access to user-chosen folders with security-scoped bookmarks.
///
/// In the sandboxed build the app may only touch folders the user picked (open panel or drag and
/// drop). A security-scoped bookmark regains that access on the next launch. Bookmarks only work on
/// the Mac that created them, so they are stored locally (keyed by the folder's portable path) and
/// never in the synced data folder. Outside the sandbox the same code works and the scope is a no-op.
enum FolderAccess {
    private static let grantsKey = "folderAccessGrants"

    // MARK: - Per-folder grants (sidebar folders)

    /// Restores this Mac's saved access to `url`, if any. Returns whether the folder can be read.
    @discardableResult
    static func restoreAccess(to url: URL) -> Bool {
        let key = PortablePath.string(url)
        if let data = grants[key], let resolved = resolve(data) {
            if let refreshed = resolved.refreshed { grants[key] = refreshed }
        }
        return canRead(url)
    }

    /// Starts access for a folder the user just granted (open panel / drop) and remembers it.
    static func rememberGrant(for url: URL) {
        guard let bookmark = grant(url) else { return }
        grants[PortablePath.string(url)] = bookmark
    }

    static func canRead(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    private static var grants: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: grantsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: grantsKey) }
    }

    // MARK: - Bookmarks

    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Resolves a bookmark and starts accessing it for the rest of the app's lifetime.
    /// Returns a refreshed bookmark when the stored one was stale (e.g. the folder was moved).
    static func resolve(_ data: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return (url, stale ? bookmark(for: url) : nil)
    }

    /// Starts access for a URL the user just granted and returns its bookmark.
    static func grant(_ url: URL) -> Data? {
        _ = url.startAccessingSecurityScopedResource()
        return bookmark(for: url)
    }

    /// Records a grant that was migrated from an older settings format.
    static func storeGrant(_ bookmark: Data, for url: URL) {
        grants[PortablePath.string(url)] = bookmark
    }
}

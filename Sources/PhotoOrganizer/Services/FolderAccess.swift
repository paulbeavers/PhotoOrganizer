import Foundation

/// Persists access to user-chosen folders with security-scoped bookmarks.
///
/// In the sandboxed build the app may only touch folders the user picked (open panel or drag and
/// drop). A security-scoped bookmark lets it regain that access on the next launch. Outside the
/// sandbox the same code works, with the scope simply being a no-op.
enum FolderAccess {
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

    /// Starts access for a URL the user just granted (open panel / drop) and returns its bookmark.
    static func grant(_ url: URL) -> Data? {
        _ = url.startAccessingSecurityScopedResource()
        return bookmark(for: url)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

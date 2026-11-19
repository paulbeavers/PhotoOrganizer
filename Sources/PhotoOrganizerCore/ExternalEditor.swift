import Foundation

/// A third-party application photos can be handed off to (Photoshop, NX Studio, ...).
public struct ExternalEditor: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var appURL: URL
    /// Lower-case file extensions this editor is preferred for (e.g. ["nef", "nrw"]).
    /// Empty means no specific preference.
    public var fileExtensions: [String]
    /// The app's bundle identifier, used to find it when `appURL` doesn't exist (e.g. settings
    /// synced from another Mac where the app is installed elsewhere).
    public var bundleIdentifier: String?

    public init(id: UUID = UUID(), name: String, appURL: URL, fileExtensions: [String] = [],
                bundleIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.appURL = appURL
        self.fileExtensions = fileExtensions.map { $0.lowercased() }
        self.bundleIdentifier = bundleIdentifier ?? Bundle(url: appURL)?.bundleIdentifier
    }

    public func handles(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Parses "nef, .NRW dng" into ["nef", "nrw", "dng"].
    public static func parseExtensions(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// Chooses which editor opens a file: an editor registered for the file's extension first,
/// then the default editor. `nil` means "use the system default app".
public func preferredEditor(for url: URL, editors: [ExternalEditor], defaultID: UUID?) -> ExternalEditor? {
    editors.first { $0.handles(url) } ?? editors.first { $0.id == defaultID }
}

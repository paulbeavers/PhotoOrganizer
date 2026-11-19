import AppKit
import Observation
import PhotoOrganizerCore

/// The configured third-party editors and how files are handed off to them.
@MainActor
@Observable
final class EditorSettings {
    private enum Keys {
        static let editors = "externalEditors"
        static let defaultEditor = "defaultEditorID"
    }

    var editors: [ExternalEditor] = [] { didSet { save() } }
    var defaultEditorID: UUID? { didSet { save() } }
    var lastError: String?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.editors),
           let saved = try? JSONDecoder().decode([ExternalEditor].self, from: data) {
            editors = saved
            defaultEditorID = defaults.string(forKey: Keys.defaultEditor).flatMap(UUID.init(uuidString:))
        } else {
            // First launch: pre-configure editors we can find.
            editors = Self.discoverEditors()
            defaultEditorID = editors.first { $0.fileExtensions.isEmpty }?.id
        }
    }

    func editor(for url: URL) -> ExternalEditor? {
        preferredEditor(for: url, editors: editors, defaultID: defaultEditorID)
    }

    /// Opens each file in its preferred editor (or `editor` if given), falling back to the system default app.
    func open(_ urls: [URL], with editor: ExternalEditor? = nil) {
        if let editor {
            open(urls, withApplicationAt: editor.appURL)
            return
        }
        var byApp: [URL: [URL]] = [:]
        var systemDefault: [URL] = []
        for url in urls {
            if let app = self.editor(for: url)?.appURL { byApp[app, default: []].append(url) } else { systemDefault.append(url) }
        }
        for (app, files) in byApp { open(files, withApplicationAt: app) }
        for url in systemDefault { NSWorkspace.shared.open(url) }
    }

    func open(_ urls: [URL], withApplicationAt appURL: URL) {
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.lastError = "Couldn't open with \(appURL.deletingPathExtension().lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func addEditorInteractively() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Editor"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !editors.contains(where: { $0.appURL == url }) {
            editors.append(ExternalEditor(name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""), appURL: url))
        }
        if defaultEditorID == nil { defaultEditorID = editors.first?.id }
    }

    func remove(_ id: UUID) {
        editors.removeAll { $0.id == id }
        if defaultEditorID == id { defaultEditorID = nil }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(editors) { defaults.set(data, forKey: Keys.editors) }
        defaults.set(defaultEditorID?.uuidString, forKey: Keys.defaultEditor)
    }

    /// Finds Photoshop and NX Studio in /Applications (they often live one folder down).
    static func discoverEditors() -> [ExternalEditor] {
        let fm = FileManager.default
        let applications = URL(fileURLWithPath: "/Applications")
        var apps: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? [] {
            if item.pathExtension == "app" {
                apps.append(item)
            } else if let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                apps += nested.filter { $0.pathExtension == "app" }
            }
        }
        // Launch Services also knows about apps outside /Applications (and works in the sandbox).
        apps += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.adobe.Photoshop")
        var result: [ExternalEditor] = []
        if let photoshop = apps.filter({ $0.lastPathComponent.hasPrefix("Adobe Photoshop") })
            .max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            result.append(ExternalEditor(name: photoshop.deletingPathExtension().lastPathComponent, appURL: photoshop))
        }
        if let nxStudio = apps.first(where: { $0.lastPathComponent == "NX Studio.app" }) {
            result.append(ExternalEditor(name: "NX Studio", appURL: nxStudio, fileExtensions: ["nef", "nrw"]))
        }
        return result
    }
}

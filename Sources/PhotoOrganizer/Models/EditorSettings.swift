import AppKit
import Observation
import PhotoOrganizerCore

/// The configured third-party editors and how files are handed off to them.
/// The editor list lives in `Settings.json` in the data folder, so it syncs between Macs.
@MainActor
@Observable
final class EditorSettings {
    let dataFolder: DataFolderModel
    var lastError: String?

    init(dataFolder: DataFolderModel) {
        self.dataFolder = dataFolder
    }

    var editors: [ExternalEditor] {
        get { dataFolder.settings.editors }
        set { dataFolder.updateSettings { $0.editors = newValue } }
    }

    var defaultEditorID: UUID? {
        get { dataFolder.settings.defaultEditorID }
        set { dataFolder.updateSettings { $0.defaultEditorID = newValue } }
    }

    func editor(for url: URL) -> ExternalEditor? {
        preferredEditor(for: url, editors: editors, defaultID: defaultEditorID)
    }

    /// Where the editor's app is on *this* Mac: its saved path, or else wherever Launch Services
    /// finds its bundle identifier (settings may come from a Mac with a different install location).
    func installedURL(of editor: ExternalEditor) -> URL? {
        if FileManager.default.fileExists(atPath: editor.appURL.path) { return editor.appURL }
        return editor.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Opens each file in its preferred editor (or `editor` if given), falling back to the system default app.
    func open(_ urls: [URL], with editor: ExternalEditor? = nil) {
        if let editor {
            launch(urls, in: editor)
            return
        }
        var byEditor: [UUID: (editor: ExternalEditor, files: [URL])] = [:]
        var systemDefault: [URL] = []
        for url in urls {
            if let editor = self.editor(for: url) {
                byEditor[editor.id, default: (editor, [])].files.append(url)
            } else {
                systemDefault.append(url)
            }
        }
        for (editor, files) in byEditor.values { launch(files, in: editor) }
        for url in systemDefault { NSWorkspace.shared.open(url) }
    }

    private func launch(_ urls: [URL], in editor: ExternalEditor) {
        guard let appURL = installedURL(of: editor) else {
            lastError = "\(editor.name) isn't installed on this Mac (looked for \(editor.appURL.path)). Update it in Settings → Editors."
            return
        }
        open(urls, withApplicationAt: appURL)
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

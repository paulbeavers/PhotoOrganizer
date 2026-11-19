import AppKit
import PhotoOrganizerCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorsSettings()
                .tabItem { Label("Editors", systemImage: "paintbrush") }
            DataFolderSettings()
                .tabItem { Label("Data Folder", systemImage: "folder") }
            CacheSettings()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .frame(width: 580, height: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        let appearance = Binding(
            get: { dataFolder.settings.appearance },
            set: { value in dataFolder.updateSettings { $0.appearance = value } })
        Form {
            Section {
                Picker("Appearance", selection: appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the Light or Dark setting in System Settings → Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Culling") {
                Toggle("Advance to the next photo after rating or flagging", isOn: $browser.autoAdvance)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorsSettings: View {
    @Environment(EditorSettings.self) private var settings
    @State private var selection: UUID?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                List(selection: $selection) {
                    ForEach($settings.editors) { $editor in
                        EditorRow(editor: $editor).tag(editor.id)
                    }
                }
                .frame(minHeight: 160)
                HStack {
                    Button {
                        settings.addEditorInteractively()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add an application")
                    Button {
                        if let selection { settings.remove(selection) }
                        selection = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected application")
                    Spacer()
                }
                .buttonStyle(.borderless)
            } header: {
                Text("External Editors")
            } footer: {
                Text("Files whose extension is listed for an editor open there; everything else opens in the default editor. Double-click a photo or press ⌘O to open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Default editor", selection: $settings.defaultEditorID) {
                Text("System default app").tag(UUID?.none)
                ForEach(settings.editors) { editor in
                    Text(editor.name).tag(Optional(editor.id))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataFolderSettings: View {
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Form {
            Section {
                LabeledContent("Location") {
                    Text(PortablePath.string(dataFolder.url))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Change…") { dataFolder.chooseFolderInteractively() }
                    Button("Show in Finder") { dataFolder.revealInFinder() }
                    if dataFolder.url != DataFolderModel.defaultURL {
                        Spacer()
                        Text("Default: ~/Pictures/Photo Organizer").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Data Folder")
            } footer: {
                Text("An ordinary folder of files, with no database or catalog: Settings.json (sidebar folders, editors and preferences), one JSON file per collection, and your keyword list (Keywords.txt, Lightroom/Bridge format). Put it in a synced folder to have the same setup on every Mac. Only the data folder's location, folder access permissions and the thumbnail cache stay on each Mac. Ratings, labels, keywords and IPTC fields are always stored in XMP sidecars next to the photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CacheSettings: View {
    @State private var usage: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent("Thumbnail cache") {
                    if let usage {
                        Text(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Button("Clear Cache") {
                        ThumbnailLoader.shared.clearDiskCache()
                        usage = 0
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ThumbnailLoader.shared.diskFolder])
                    }
                }
            } footer: {
                Text("Thumbnails are cached on disk so folders open instantly. The cache is trimmed automatically to \(ByteCountFormatter.string(fromByteCount: ThumbnailLoader.diskCacheLimit, countStyle: .file)) and can be deleted at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            usage = await Task.detached(priority: .utility) { ThumbnailLoader.shared.diskUsage() }.value
        }
    }
}

private struct EditorRow: View {
    @Binding var editor: ExternalEditor
    @State private var extensionsText = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: editor.appURL.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $editor.name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Text(editor.appURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Extensions (e.g. nef, nrw)", text: $extensionsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .onSubmit(commitExtensions)
                .onChange(of: extensionsText) { commitExtensions() }
                .help("File types to open with this editor instead of the default")
        }
        .padding(.vertical, 2)
        .onAppear { extensionsText = editor.fileExtensions.joined(separator: ", ") }
    }

    private func commitExtensions() {
        let parsed = ExternalEditor.parseExtensions(extensionsText)
        if parsed != editor.fileExtensions { editor.fileExtensions = parsed }
    }
}

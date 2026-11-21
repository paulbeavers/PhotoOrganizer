import AppKit
import PhotoOrganizerCore
import SwiftUI

struct SidebarView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(ImportModel.self) private var importer

    @AppStorage("sidebarImportsExpanded") private var importsExpanded = true
    @AppStorage("sidebarSmartExpanded") private var smartExpanded = true
    @AppStorage("sidebarManualExpanded") private var manualExpanded = true

    var body: some View {
        let selection = Binding<BrowseSource?>(
            get: { browser.source },
            set: { source in
                guard let source else { return }
                if case .folder(let url) = source, !browser.isAccessible(url) {
                    browser.grantAccessInteractively(to: url)
                } else {
                    browser.open(source)
                }
            })

        List(selection: selection) {
            Section("Folders") {
                OutlineGroup(browser.rootNodes, children: \.children) { node in
                    FolderRow(node: node)
                        .tag(BrowseSource.folder(node.url))
                }
            }
            Section("Collections") {
                // Every import, newest first: a collection by import date and time.
                if !dataFolder.importSessions.isEmpty {
                    DisclosureGroup(isExpanded: $importsExpanded) {
                        ForEach(dataFolder.importSessions) { session in
                            ImportSessionRow(session: session)
                                .tag(BrowseSource.importSession(session.id))
                        }
                    } label: {
                        Label("Imports", systemImage: "tray.full")
                            .badge(dataFolder.importSessions.count)
                    }
                }
                // Smart collections get a group of their own, like Imports.
                let smart = dataFolder.collections.filter { $0.kind == .smart }
                if !smart.isEmpty {
                    DisclosureGroup(isExpanded: $smartExpanded) {
                        ForEach(smart) { collection in
                            CollectionRow(collection: collection)
                                .tag(BrowseSource.collection(collection.id))
                        }
                    } label: {
                        Label("Smart Collections", systemImage: "sparkles.rectangle.stack")
                            .badge(smart.count)
                    }
                }
                // Hand-picked collections, grouped like the others.
                let manual = dataFolder.collections.filter { $0.kind == .manual }
                if !manual.isEmpty {
                    DisclosureGroup(isExpanded: $manualExpanded) {
                        ForEach(manual) { collection in
                            CollectionRow(collection: collection)
                                .tag(BrowseSource.collection(collection.id))
                        }
                    } label: {
                        Label("Collections", systemImage: "rectangle.stack")
                            .badge(manual.count)
                    }
                }
                if dataFolder.collections.isEmpty && dataFolder.importSessions.isEmpty {
                    Text("Use “Add to Collection” on photos, or save a search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            // Folders dropped on empty sidebar space are added to the sidebar.
            browser.handleDrop(urls, onto: nil, copy: false)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Import Photos…") { importer.present() }
                    Divider()
                    Button("Add Folder to Sidebar…") { browser.addRootFoldersInteractively() }
                    Button("New Collection…") {
                        browser.namePrompt = NamePrompt(purpose: .newCollection(adding: []))
                    }
                    Button("New Smart Collection…") { browser.newSmartCollection() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct FolderRow: View {
    @Environment(BrowserModel.self) private var browser
    let node: FolderNode
    @State private var isTargeted = false

    var body: some View {
        Label(node.name, systemImage: !node.isAccessible ? "lock.fill" : browser.isRoot(node.url) ? "folder.fill" : "folder")
            .lineLimit(1)
            .foregroundStyle(node.isAccessible ? .primary : .secondary)
            .help(node.isAccessible ? node.url.path : "\(node.url.path)\nClick to grant this Mac access to the folder.")
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.3) : .clear))
            .dropDestination(for: URL.self) { urls, _ in
                browser.handleDrop(urls, onto: node.url, copy: NSEvent.modifierFlags.contains(.option))
            } isTargeted: { isTargeted = $0 }
            .contextMenu {
                if !node.isAccessible {
                    Button("Grant Access…") { browser.grantAccessInteractively(to: node.url) }
                    Divider()
                }
                Button("New Folder…") {
                    browser.namePrompt = NamePrompt(purpose: .newFolder(in: node.url))
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                if browser.isRoot(node.url) {
                    Divider()
                    Button("Remove from Sidebar") { browser.removeRootFolder(node.url) }
                }
            }
    }
}

/// One import: when, from where, how many photos. The running import shows its progress.
private struct ImportSessionRow: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(ImportModel.self) private var importer
    let session: ImportSession

    var body: some View {
        let isRunning = importer.runningSessionID == session.id
        // Always two one-line rows: a row that changes height inside the list leaves stale copies
        // of itself behind.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(session.started.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isRunning {
                    let p = importer.progress
                    ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Button {
                        importer.cancelImport()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop importing (files already copied stay)")
                }
            }
            Text(detail(isRunning: isRunning))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("Imported \(session.started.formatted(date: .long, time: .standard)) from \(session.source)"
              + (importer.lastSessionID == session.id ? "\n" + (importer.lastSummary ?? "") : ""))
        .contextMenu {
            Button("Save as Collection…") {
                browser.namePrompt = NamePrompt(purpose: .newCollection(adding: session.fileURLs),
                                                initialName: "Import " + session.started.formatted(.iso8601.year().month().day()))
            }
            Divider()
            Button("Remove from Imports") {
                if browser.source == .importSession(session.id) { browser.close() }
                dataFolder.removeImportSession(session)
            }
            .help("Removes this entry from the list; the photos stay where they are")
        }
    }
}

extension ImportSessionRow {
    /// "NIKON Z 8 · 5 photos", "NIKON Z 8 · 3 of 5", or the latest import's outcome
    /// ("NIKON Z 8 · 5 photos · card ejected").
    fileprivate func detail(isRunning: Bool) -> String {
        if isRunning {
            let p = importer.progress
            return "\(session.source) · \(p.filesDone) of \(p.filesTotal)"
        }
        if importer.lastSessionID == session.id, let summary = importer.lastSummary {
            return "\(session.source) · " + summary.replacingOccurrences(of: "Imported ", with: "")
        }
        return "\(session.source) · \(session.files.count) photo\(session.files.count == 1 ? "" : "s")"
    }
}

private struct CollectionRow: View {
    @Environment(BrowserModel.self) private var browser
    let collection: PhotoCollection
    @State private var isTargeted = false

    var body: some View {
        Label {
            HStack {
                Text(collection.name).lineLimit(1)
                Spacer()
                if collection.kind == .manual {
                    Text("\(collection.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: collection.kind == .smart ? "sparkles" : "rectangle.stack")
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.3) : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            guard collection.kind == .manual else { return false }
            var files = urls
            if files.count == 1, browser.selection.contains(files[0]) { files = browser.selectedURLs }
            browser.dataFolder.add(browser.includingStacks(files), to: collection.id)
            return true
        } isTargeted: { isTargeted = $0 && collection.kind == .manual }
        .contextMenu {
            if collection.kind == .smart {
                Button("Edit Smart Collection…") { browser.editSmartCollection(collection.id) }
            }
            Button("Rename…") {
                browser.namePrompt = NamePrompt(purpose: .renameCollection(collection.id), initialName: collection.name)
            }
            Button("Reveal File in Finder") {
                browser.dataFolder.revealInFinder()
            }
            Divider()
            Button("Delete Collection", role: .destructive) {
                browser.deleteCollection(collection.id)
            }
        }
    }
}

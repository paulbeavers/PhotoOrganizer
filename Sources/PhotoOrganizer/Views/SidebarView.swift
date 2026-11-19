import AppKit
import PhotoOrganizerCore
import SwiftUI

struct SidebarView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(ImportModel.self) private var importer

    private var hasLastImport: Bool {
        importer.isImporting || !browser.lastImportURLs.isEmpty || importer.lastSummary != nil
    }

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
                // The running or most recent import, first among the collections.
                if hasLastImport {
                    LastImportRow()
                        .tag(BrowseSource.lastImport)
                }
                ForEach(dataFolder.collections) { collection in
                    CollectionRow(collection: collection)
                        .tag(BrowseSource.collection(collection.id))
                }
                if dataFolder.collections.isEmpty && !hasLastImport {
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

/// "Last Import" in the sidebar, with live progress while copying.
private struct LastImportRow: View {
    @Environment(ImportModel.self) private var importer
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Last Import", systemImage: "clock.arrow.circlepath")
                Spacer()
                if importer.isImporting {
                    Button {
                        importer.cancelImport()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop importing (files already copied stay)")
                } else {
                    Text("\(browser.lastImportURLs.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if importer.isImporting {
                let p = importer.progress
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    .controlSize(.small)
                Text("\(p.filesDone) of \(p.filesTotal) · \(p.currentName)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if let summary = importer.lastSummary {
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
            Image(systemName: collection.kind == .smart ? "gearshape" : "rectangle.stack")
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

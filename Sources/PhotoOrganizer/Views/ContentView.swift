import PhotoOrganizerCore
import SwiftUI

struct ContentView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(EditorSettings.self) private var editors
    @Environment(DataFolderModel.self) private var dataFolder
    @Environment(ImportModel.self) private var importer
    @State private var showInspector = true
    /// The main window's size; the import sheet fills most of it.
    @State private var windowSize = CGSize(width: 1200, height: 800)

    var body: some View {
        @Bindable var browser = browser

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 400)
        } detail: {
            VStack(spacing: 0) {
                FilterBar()
                PhotoGridView()
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 280, ideal: 330, max: 560)
            }
        }
        .navigationTitle(browser.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $browser.criteria.text, placement: .toolbar, prompt: "Name, keyword, caption…")
        .toolbar {
            // Where photos come in, in plain sight: opens the import window.
            ToolbarItem(placement: .navigation) {
                Button {
                    importer.present()
                } label: {
                    Label("Add Photos", systemImage: "plus.rectangle.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Import photos from a card or a folder (⇧⌘I)")
                .disabled(importer.isImporting)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if browser.currentFolder != nil {
                    Toggle(isOn: $browser.includeSubfolders) {
                        Label("Include Subfolders", systemImage: "square.stack.3d.down.right")
                    }
                    .help("Show photos from all subfolders")
                }
                FilterMenu()
                SortMenu()
            }
            // The slider gets its own toolbar item so it never shares (and overlaps) space with the menus.
            ToolbarItem(placement: .primaryAction) {
                ThumbnailSizeSlider(size: $browser.thumbnailSize)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    browser.startReview()
                } label: {
                    Label("Review", systemImage: "rectangle.on.rectangle")
                }
                .help("Review the selection full-size; select 2–4 photos to compare (Space)")
                .disabled(browser.visiblePhotos.isEmpty)
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .overlay {
            if browser.isReviewing {
                ReviewView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: browser.isReviewing)
        // Settings.json, collections and keywords may have been changed by another Mac via sync.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dataFolder.reload()
        }
        .onChange(of: dataFolder.settings.sidebarFolders) {
            browser.syncSidebarWithSettings()
        }
        .onChange(of: dataFolder.settings.appearance) {
            dataFolder.applyAppearance()
        }
        .onChange(of: dataFolder.settings.stackSameName) {
            browser.rebuildGrid()
        }
        .onChange(of: dataFolder.settings.stackCover) {
            browser.rebuildGrid()
        }
        .sheet(item: $browser.namePrompt) { prompt in
            NamePromptSheet(prompt: prompt)
        }
        .sheet(item: $browser.smartEditor) { request in
            SmartCollectionEditor(request: request)
        }
        .sheet(item: $browser.renameRequest) { request in
            BatchRenameSheet(urls: request.urls)
        }
        .sheet(isPresented: Binding(get: { importer.isPresented }, set: { importer.isPresented = $0 })) {
            // As large as the main window allows (a sheet can't be bigger than its window), so the
            // photo grid shows as many thumbnails as possible.
            ImportView()
                .frame(width: max(900, windowSize.width - 60), height: max(560, windowSize.height - 60))
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { windowSize = $0 }
        .alert("Import", isPresented: errorBinding(\.errorMessage, on: importer)) {
            Button("OK") { importer.errorMessage = nil }
        } message: {
            Text(importer.errorMessage ?? "")
        }
        .confirmationDialog(trashTitle, isPresented: Binding(
            get: { browser.trashRequest != nil },
            set: { if !$0 { browser.trashRequest = nil } }
        ), presenting: browser.trashRequest) { request in
            Button("Move to Trash", role: .destructive) { browser.moveToTrash(request.urls) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their NX Studio, RawTherapee and DxO edit files go to the Trash too. XMP sidecars are trashed unless another file still shares them.")
        }
        .alert("Move exports to the Trash?", isPresented: Binding(
            get: { browser.cullCleanupRequest != nil },
            set: { if !$0 { browser.cullCleanupRequest = nil } }
        ), presenting: browser.cullCleanupRequest) { request in
            Button("Move to Trash", role: .destructive) { request.confirm() }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            let names = request.files.map(\.lastPathComponent)
            Text("These photos leave the Picked folder (with their edits). These files exported from them there go to the Trash:\n\n"
                 + names.prefix(12).joined(separator: "\n")
                 + (names.count > 12 ? "\n…and \(names.count - 12) more" : ""))
        }
        .alert("Something went wrong", isPresented: errorBinding(\.errorMessage, on: browser)) {
            Button("OK") { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "")
        }
        .alert("Couldn't open file", isPresented: errorBinding(\.lastError, on: editors)) {
            Button("OK") { editors.lastError = nil }
        } message: {
            Text(editors.lastError ?? "")
        }
        .alert("Couldn't save to the data folder", isPresented: errorBinding(\.errorMessage, on: dataFolder)) {
            Button("OK") { dataFolder.errorMessage = nil }
        } message: {
            Text(dataFolder.errorMessage ?? "")
        }
    }

    private var trashTitle: String {
        let count = browser.trashRequest?.urls.count ?? 0
        return "Move \(count) photo\(count == 1 ? "" : "s") to the Trash?"
    }

    private var subtitle: String {
        guard browser.source != nil else { return "" }
        let shown = browser.visiblePhotos.count, total = browser.photos.count
        var text = shown == total ? "\(total) photos" : "\(shown) of \(total) photos"
        if !browser.selection.isEmpty { text += " · \(browser.selection.count) selected" }
        if browser.isLoading { text += " · loading…" }
        return text
    }

    private func errorBinding<Model: AnyObject>(_ keyPath: ReferenceWritableKeyPath<Model, String?>, on model: Model) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }
}

/// Shows active filters as removable chips, plus smart-collection actions.
private struct FilterBar: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let criteria = browser.criteria
        let smart = browser.currentCollection.flatMap { $0.kind == .smart ? $0 : nil }
        if !criteria.isEmpty || smart != nil {
            HStack(spacing: 6) {
                Image(systemName: smart != nil ? "sparkles" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let smart {
                            Text(SmartRulesSummary.text(for: smart.effectiveRules))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !criteria.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            chip("“\(criteria.text)”") { browser.criteria.text = "" }
                        }
                        if criteria.minimumRating > 0 {
                            chip(String(repeating: "★", count: criteria.minimumRating) + (criteria.minimumRating < 5 ? "+" : "")) {
                                browser.criteria.minimumRating = 0
                            }
                        }
                        if let label = criteria.label {
                            chip(label.rawValue, color: label.color) { browser.criteria.label = nil }
                        }
                        if criteria.flag != .any {
                            chip(criteria.flag.displayName) { browser.criteria.flag = .any }
                        }
                        ForEach(criteria.keywords, id: \.self) { keyword in
                            chip(Keyword.display(keyword), systemImage: "tag") {
                                browser.criteria.keywords.removeAll { $0 == keyword }
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                if let smart {
                    Button("Edit Rules…") { browser.editSmartCollection(smart.id) }
                        .help("Change what this smart collection includes")
                } else {
                    Button("Save as Smart Collection…") { browser.saveSearchAsSmartCollection() }
                }
                if !criteria.isEmpty {
                    Button("Clear") { browser.criteria = SearchCriteria() }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func chip(_ text: String, color: Color? = nil, systemImage: String? = nil, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

private struct FilterMenu: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Menu {
            Picker("Minimum Rating", selection: $browser.criteria.minimumRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + (stars < 5 ? " or more" : "")).tag(stars)
                }
            }
            Picker("Label", selection: $browser.criteria.label) {
                Text("Any Label").tag(ColorLabel?.none)
                ForEach(ColorLabel.allCases) { label in
                    Text(label.rawValue).tag(Optional(label))
                }
            }
            Picker("Flag", selection: $browser.criteria.flag) {
                ForEach(FlagFilter.allCases) { Text($0.displayName).tag($0) }
            }
            Menu("Keyword") {
                let tree = KeywordNode.tree(from: browser.loadedKeywords)
                if tree.isEmpty {
                    Text("No keywords on these photos")
                } else {
                    ForEach(tree) { KeywordFilterItem(node: $0) }
                    if !browser.criteria.keywords.isEmpty {
                        Divider()
                        Button("Clear Keyword Filters") { browser.criteria.keywords = [] }
                    }
                }
            }
            Divider()
            Button("Clear Filters") { browser.criteria = SearchCriteria() }
                .disabled(browser.criteria.isEmpty)
        } label: {
            Label("Filter", systemImage: browser.criteria.isEmpty
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by rating, label, flag or keyword")
    }
}

/// One keyword in the filter menu. Keywords with children become submenus whose first item filters
/// by the keyword itself (which also matches all of its children).
private struct KeywordFilterItem: View {
    @Environment(BrowserModel.self) private var browser
    let node: KeywordNode

    var body: some View {
        if let children = node.children {
            Menu(node.name) {
                toggle(title: "All “\(node.name)”")
                Divider()
                ForEach(children) { KeywordFilterItem(node: $0) }
            }
        } else {
            toggle(title: node.name)
        }
    }

    private func toggle(title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { browser.criteria.keywords.contains { $0.caseInsensitiveCompare(node.path) == .orderedSame } },
            set: { isOn in
                browser.criteria.keywords.removeAll { $0.caseInsensitiveCompare(node.path) == .orderedSame }
                if isOn { browser.criteria.keywords.append(node.path) }
            }))
    }
}

private struct ThumbnailSizeSlider: View {
    @Binding var size: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").imageScale(.small)
            Slider(value: $size, in: 96...360)
                .frame(width: 100)
            Image(systemName: "photo").imageScale(.large)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .fixedSize()
        .help("Thumbnail size")
    }
}

private struct SortMenu: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Menu {
            Picker("Sort By", selection: $browser.sortOrder) {
                ForEach(PhotoSortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Ascending", isOn: $browser.sortAscending)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort order")
    }
}

/// A small sheet asking for a name (collections, folders).
struct NamePromptSheet: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let prompt: NamePrompt
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = prompt.initialName }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        browser.submitNamePrompt(prompt, name: name)
        dismiss()
    }
}

extension ColorLabel {
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}

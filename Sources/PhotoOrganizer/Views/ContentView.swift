import PhotoOrganizerCore
import SwiftUI

struct ContentView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(EditorSettings.self) private var editors
    @Environment(LibraryModel.self) private var library
    @State private var showInspector = true

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
            ToolbarItemGroup(placement: .primaryAction) {
                if browser.currentFolder != nil {
                    Toggle(isOn: $browser.includeSubfolders) {
                        Label("Include Subfolders", systemImage: "square.stack.3d.down.right")
                    }
                    .help("Show photos from all subfolders")
                }
                FilterMenu()
                SortMenu()
                Slider(value: $browser.thumbnailSize, in: 96...360)
                    .frame(width: 100)
                    .help("Thumbnail size")
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
        .sheet(item: $browser.namePrompt) { prompt in
            NamePromptSheet(prompt: prompt)
        }
        .sheet(item: $browser.renameRequest) { request in
            BatchRenameSheet(urls: request.urls)
        }
        .confirmationDialog(trashTitle, isPresented: Binding(
            get: { browser.trashRequest != nil },
            set: { if !$0 { browser.trashRequest = nil } }
        ), presenting: browser.trashRequest) { request in
            Button("Move to Trash", role: .destructive) { browser.moveToTrash(request.urls) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their XMP sidecars are moved to the Trash too, unless another file still shares them.")
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
        .alert("Library problem", isPresented: errorBinding(\.errorMessage, on: library)) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
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
        let isSmart = browser.currentCollection?.kind == .smart
        if !criteria.isEmpty || isSmart {
            HStack(spacing: 6) {
                Image(systemName: isSmart ? "gearshape" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
                        if criteria.isEmpty {
                            Text("No criteria. This smart collection shows every photo in its folders.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if isSmart {
                    if browser.hasUnsavedSmartChanges {
                        Button("Save Changes") { browser.saveSmartCollectionChanges() }
                            .help("Update the smart collection with these filters")
                    }
                } else {
                    Button("Save as Smart Collection…") {
                        browser.namePrompt = NamePrompt(purpose: .saveSmartCollection)
                    }
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
            Divider()
            Button("Clear Filters") { browser.criteria = SearchCriteria() }
                .disabled(browser.criteria.isEmpty)
        } label: {
            Label("Filter", systemImage: browser.criteria.isEmpty
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by rating, label or flag")
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

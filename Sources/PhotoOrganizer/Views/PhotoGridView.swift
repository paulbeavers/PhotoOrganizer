import AppKit
import PhotoOrganizerCore
import SwiftUI

struct PhotoGridView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(EditorSettings.self) private var editors
    @FocusState private var isFocused: Bool
    @State private var width: CGFloat = 0

    private let spacing: CGFloat = 10
    private let padding: CGFloat = 16
    private var cellWidth: CGFloat { browser.thumbnailSize + PhotoCell.inset * 2 }
    private var columnCount: Int { max(1, Int((width - padding * 2 + spacing) / (cellWidth + spacing))) }

    var body: some View {
        let photos = browser.visiblePhotos
        Group {
            if browser.source == nil {
                ContentUnavailableView("Nothing Selected", systemImage: "folder",
                                       description: Text("Choose a folder or collection in the sidebar, or add a folder with ⇧⌘O."))
            } else if photos.isEmpty {
                if browser.isLoading {
                    ProgressView()
                } else if browser.photos.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text(browser.currentCollection?.kind == .manual
                                                             ? "Drag photos onto this collection in the sidebar, or use “Add to Collection”."
                                                             : "There are no images here."))
                } else {
                    ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No photos match the current filters."))
                }
            } else {
                grid(photos)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let extend = press.modifiers.contains(.shift)
            switch press.key {
            case .leftArrow: browser.moveSelection(by: -1, extend: extend)
            case .rightArrow: browser.moveSelection(by: 1, extend: extend)
            case .upArrow: browser.moveSelection(by: -columnCount, extend: extend)
            default: browser.moveSelection(by: columnCount, extend: extend)
            }
            return .handled
        }
        .onKeyPress(.return) {
            editors.open(browser.selectedURLs)
            return .handled
        }
        .onKeyPress(.space) {
            browser.startReview()
            return .handled
        }
        .onKeyPress(.escape) {
            browser.clearSelection()
            return .handled
        }
        .onKeyPress(.delete) {
            guard !browser.selection.isEmpty else { return .ignored }
            browser.trashRequest = FileRequest(urls: browser.selectedURLs)
            return .handled
        }
        .onKeyPress(characters: CullingKeys.characters) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            return CullingKeys.handle(press.characters, browser: browser) ? .handled : .ignored
        }
        .onAppear { isFocused = true }
    }

    private func grid(_ photos: [PhotoFile]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columnCount),
                          spacing: spacing) {
                    ForEach(photos) { photo in
                        PhotoCell(photo: photo,
                                  tags: browser.tags[photo.url],
                                  isSelected: browser.selection.contains(photo.url),
                                  size: browser.thumbnailSize,
                                  showsFolder: browser.includeSubfolders || browser.currentFolder == nil)
                            .id(photo.url)
                            .gesture(TapGesture(count: 2).onEnded {
                                editors.open(browser.targets(for: photo.url))
                            })
                            .simultaneousGesture(TapGesture().onEnded {
                                browser.click(photo.url, modifiers: NSEvent.modifierFlags)
                                isFocused = true
                            })
                            .draggable(photo.url) {
                                DragPreview(photo: photo, count: browser.selection.contains(photo.url) ? browser.selection.count : 1)
                            }
                            .contextMenu { PhotoContextMenu(url: photo.url) }
                    }
                }
                .padding(padding)
                .frame(maxWidth: .infinity)
            }
            .background {
                // Clicking empty space clears the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        browser.clearSelection()
                        isFocused = true
                    }
            }
            .onChange(of: browser.focused) { _, focused in
                if let focused { proxy.scrollTo(focused) }
            }
            .onChange(of: browser.isReviewing) { _, reviewing in
                if !reviewing { isFocused = true }
            }
        }
    }
}

/// Single-key culling shortcuts shared by the grid and the review view.
enum CullingKeys {
    static let characters = CharacterSet(charactersIn: "012345pPxXuU6789")

    @MainActor
    static func handle(_ characters: String, browser: BrowserModel, urls: [URL]? = nil) -> Bool {
        switch characters.lowercased() {
        case "0", "1", "2", "3", "4", "5": browser.setRating(Int(characters)!, for: urls)
        case "p": browser.pick(urls)
        case "x": browser.reject(urls)
        case "u": browser.unflag(urls)
        case "6": browser.toggleLabel(.red, for: urls)
        case "7": browser.toggleLabel(.yellow, for: urls)
        case "8": browser.toggleLabel(.green, for: urls)
        case "9": browser.toggleLabel(.blue, for: urls)
        default: return false
        }
        return true
    }
}

private struct DragPreview: View {
    let photo: PhotoFile
    let count: Int

    var body: some View {
        Label(count > 1 ? "\(count) photos" : photo.name, systemImage: "photo")
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PhotoCell: View {
    static let inset: CGFloat = 6

    let photo: PhotoFile
    let tags: PhotoTags?
    let isSelected: Bool
    let size: CGFloat
    var showsFolder = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    /// Request sizes in 256px steps so dragging the size slider doesn't reload every frame.
    private var pixelSize: Int {
        let needed = Int(size * displayScale)
        return ((needed + 255) / 256) * 256
    }

    private var isRejected: Bool { tags?.isRejected ?? false }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size, height: size)
            .opacity(isRejected ? 0.35 : 1)
            .overlay(alignment: .topLeading) { flagBadge }
            .overlay(alignment: .topTrailing) {
                if let label = tags?.label {
                    Circle().fill(label.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .padding(4)
                }
            }

            Text(photo.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
            if showsFolder {
                Text(photo.url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size)
            }
            Text(stars)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .padding(Self.inset)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(photo.url.path)
        .task(id: "\(photo.url.path)|\(photo.modified.timeIntervalSinceReferenceDate)|\(pixelSize)") {
            image = await ThumbnailLoader.shared.image(for: photo.url, modified: photo.modified, maxPixelSize: pixelSize)
        }
    }

    @ViewBuilder private var flagBadge: some View {
        if isRejected {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white, .red)
                .font(.body)
                .padding(4)
        } else if tags?.isPicked == true {
            Image(systemName: "flag.circle.fill")
                .foregroundStyle(.white, .green)
                .font(.body)
                .padding(4)
        }
    }

    private var stars: String {
        let rating = tags?.rating ?? 0
        return rating > 0 ? String(repeating: "★", count: rating) : " "
    }
}

struct PhotoContextMenu: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(EditorSettings.self) private var editors
    @Environment(LibraryModel.self) private var library
    let url: URL

    var body: some View {
        let targets = browser.targets(for: url)
        let plural = targets.count > 1 ? " \(targets.count) Photos" : ""
        Button("Open in \(editors.editor(for: url)?.name ?? "Default App")") { editors.open(targets) }
        Menu("Open With") {
            ForEach(editors.editors) { editor in
                Button(editor.name) { editors.open(targets, with: editor) }
            }
            if !editors.editors.isEmpty { Divider() }
            ForEach(otherApps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) {
                    editors.open(targets, withApplicationAt: app)
                }
            }
        }
        Button("Review\(plural)") {
            if !browser.selection.contains(url) { browser.select(url) }
            browser.startReview()
        }
        Divider()
        Menu("Rating") {
            ForEach(0...5, id: \.self) { rating in
                Button(rating == 0 ? "No Rating" : String(repeating: "★", count: rating)) {
                    browser.setRating(rating, for: targets)
                }
            }
        }
        Menu("Label") {
            ForEach(ColorLabel.allCases) { label in
                Button(label.rawValue) { browser.setLabel(label, for: targets) }
            }
            Divider()
            Button("No Label") { browser.setLabel(nil, for: targets) }
        }
        Menu("Flag") {
            Button("Pick") { browser.pick(targets) }
            Button("Reject") { browser.reject(targets) }
            Button("Unflag") { browser.unflag(targets) }
        }
        Menu("Add to Collection") {
            ForEach(library.collections.filter { $0.kind == .manual }) { collection in
                Button(collection.name) { library.add(targets, to: collection.id) }
            }
            Divider()
            Button("New Collection…") {
                browser.namePrompt = NamePrompt(purpose: .newCollection(adding: targets))
            }
        }
        if browser.currentCollection?.kind == .manual {
            Button("Remove from Collection") { browser.removeFromCurrentCollection(targets) }
        }
        Divider()
        Menu("Move To") { destinationMenu(targets, move: true) }
        Menu("Copy To") { destinationMenu(targets, move: false) }
        Button("Rename\(plural)…") { browser.renameRequest = FileRequest(urls: targets) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { browser.trashRequest = FileRequest(urls: targets) }
    }

    @ViewBuilder
    private func destinationMenu(_ targets: [URL], move: Bool) -> some View {
        ForEach(browser.rootNodes) { node in
            Button(node.name) {
                if move { browser.move(targets, to: node.url) } else { browser.copy(targets, to: node.url) }
            }
        }
        Divider()
        Button("Choose Folder…") { browser.transferInteractively(targets, move: move) }
    }

    private var otherApps: [URL] {
        let configured = Set(editors.editors.map(\.appURL))
        return NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { !configured.contains($0) }
            .prefix(15)
            .map { $0 }
    }
}

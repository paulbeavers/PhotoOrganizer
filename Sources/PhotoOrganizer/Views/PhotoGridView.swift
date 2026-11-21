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
                grid(browser.gridItems)
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
            browser.trashRequest = FileRequest(urls: browser.includingStacks(browser.selectedURLs))
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            browser.toggleFocusedStack()
            return .handled
        }
        .onKeyPress(characters: CullingKeys.characters) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            return CullingKeys.handle(press.characters, browser: browser) ? .handled : .ignored
        }
        .onAppear { isFocused = true }
    }

    private func grid(_ items: [GridEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columnCount),
                          spacing: spacing) {
                    ForEach(items) { item in
                        let photo = item.photo
                        PhotoCell(photo: photo,
                                  tags: browser.tags[photo.url],
                                  editedIn: browser.edits[photo.url] ?? [],
                                  isSelected: browser.selection.contains(photo.url),
                                  size: browser.thumbnailSize,
                                  showsFolder: browser.includeSubfolders || browser.currentFolder == nil,
                                  stack: item.stack)
                            .id(photo.url)
                            .gesture(TapGesture(count: 2).onEnded {
                                editors.open(browser.targets(for: photo.url))
                            })
                            .simultaneousGesture(TapGesture().onEnded {
                                browser.click(photo.url, modifiers: NSEvent.modifierFlags)
                                isFocused = true
                            })
                            .draggable(photo.url) {
                                DragPreview(photo: photo, count: browser.includingStacks(
                                    browser.selection.contains(photo.url) ? browser.selectedURLs : [photo.url]).count)
                            }
                            .contextMenu { PhotoContextMenu(url: photo.url) }
                            // Added *after* the cell's click, double-click and drag gestures, so the
                            // arrow is a separate layer they never see: every click on it toggles.
                            .overlay(alignment: .bottomTrailing) {
                                if let stack = item.stack, stack.isTop {
                                    StackArrowButton(stack: stack) { browser.toggleStack(stack.key) }
                                        .padding(PhotoCell.inset)
                                }
                            }
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

/// The expand / collapse arrow in the bottom-right corner of a stack's top photo.
struct StackArrowButton: View {
    let stack: StackInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: stack.isExpanded ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.orange)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(3)                     // a comfortable click target
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(stack.isExpanded ? "Collapse the stack (S)" : "Show the \(stack.count) files in this stack (S)")
        .accessibilityLabel(stack.isExpanded ? "Collapse stack" : "Expand stack")
    }
}

struct PhotoCell: View {
    static let inset: CGFloat = 6

    let photo: PhotoFile
    let tags: PhotoTags?
    /// Apps whose own settings files hold edits for this photo (not shown in the preview).
    var editedIn: [String] = []
    let isSelected: Bool
    let size: CGFloat
    var showsFolder = false
    /// Set when the photo is part of a stack of same-name files.
    var stack: StackInfo? = nil

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
            .overlay(alignment: .bottomLeading) { stackBadge }
            .overlay(alignment: .topTrailing) {
                if let label = tags?.label {
                    Circle().fill(label.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .padding(4)
                }
            }

            // A faint mark after the name when another app holds edits the preview can't show.
            (Text(photo.name)
                + (editedIn.isEmpty ? Text("") : Text(" ") + Text(Image(systemName: "slider.horizontal.3"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
                .help(editedIn.isEmpty ? photo.name : "Edited in \(editedIn.joined(separator: ", ")) (not shown in the preview)")
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
        // Every cell gets a light gray box; selection swaps it for the accent color.
        // `primary` with low opacity reads as light gray in Light Mode and stays subtle in Dark Mode.
        .background {
            ZStack {
                // A closed stack's sheets sit behind the cell; an opaque base keeps them from
                // showing through its translucent fill.
                if let stack, !stack.isExpanded {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                }
                RoundedRectangle(cornerRadius: 8).fill(boxFill)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(boxStroke, lineWidth: isSelected ? 2 : 1))
        // A collapsed stack looks like a pile of prints: two more boxes peek out behind it.
        .background {
            if let stack, !stack.isExpanded {
                ZStack {
                    stackSheet.offset(x: 7, y: 7)
                    stackSheet.offset(x: 3.5, y: 3.5)
                }
            }
        }
        .contentShape(Rectangle())
        .help(photo.url.path)
        .task(id: "\(photo.url.path)|\(photo.modified.timeIntervalSinceReferenceDate)|\(pixelSize)") {
            image = await ThumbnailLoader.shared.image(for: photo.url, modified: photo.modified, maxPixelSize: pixelSize)
        }
    }

    // MARK: Box and stack

    private var isExpandedStackMember: Bool { stack?.isExpanded == true }

    private var boxFill: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        // The files of an open stack share a warm tint so they read as one group.
        return isExpandedStackMember ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05)
    }

    private var boxStroke: Color {
        if isSelected { return Color.accentColor }
        return isExpandedStackMember ? Color.orange.opacity(0.55) : Color.primary.opacity(0.15)
    }

    private var stackSheet: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
    }

    /// "NEF+JPG" on a closed stack, "1/2" on each file of an open one.
    @ViewBuilder private var stackBadge: some View {
        if let stack {
            HStack(spacing: 3) {
                Image(systemName: "square.stack.fill")
                Text(stack.isExpanded ? "\(stack.index + 1)/\(stack.count)"
                     : stack.count <= 3 ? stack.extensions.joined(separator: "+") : "\(stack.count)")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(4)
            .help(stack.isExpanded ? "File \(stack.index + 1) of \(stack.count) in this stack"
                  : "A stack of \(stack.count) files with this name: \(stack.extensions.joined(separator: ", "))")
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
    @Environment(DataFolderModel.self) private var dataFolder
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
        if browser.stacksEnabled, browser.isInStack(url) {
            let key = BrowserModel.stackKey(for: url)
            Button(browser.expandedStacks.contains(key) ? "Collapse Stack" : "Expand Stack") { browser.toggleStack(key) }
        }
        Button("Review\(plural)") {
            if !browser.selection.contains(url) { browser.select(url) }
            browser.startReview()
        }
        Divider()
        Button("Pick") { browser.pick(targets) }
        Button("Unflag") { browser.unflag(targets) }
        Button("Reject") { browser.reject(targets) }
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
        Menu("Add to Collection") {
            ForEach(dataFolder.collections.filter { $0.kind == .manual }) { collection in
                Button(collection.name) { dataFolder.add(browser.includingStacks(targets), to: collection.id) }
            }
            Divider()
            Button("New Collection…") {
                browser.namePrompt = NamePrompt(purpose: .newCollection(adding: browser.includingStacks(targets)))
            }
        }
        if browser.currentCollection?.kind == .manual {
            Button("Remove from Collection") { browser.removeFromCurrentCollection(targets) }
        }
        Divider()
        Menu("Move To") { destinationMenu(targets, move: true) }
        Menu("Copy To") { destinationMenu(targets, move: false) }
        Button("Rename\(plural)…") { browser.renameRequest = FileRequest(urls: browser.includingStacks(targets)) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { browser.trashRequest = FileRequest(urls: browser.includingStacks(targets)) }
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

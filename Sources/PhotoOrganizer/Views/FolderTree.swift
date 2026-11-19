import PhotoOrganizerCore
import SwiftUI

/// A folder in a Finder-style tree (main sidebar and import window). Its subfolders are read only
/// when it's expanded, so showing the tree never touches folders macOS protects (Desktop,
/// Documents, Downloads) until the user opens one.
///
/// Rows are only ever places. Commands belong in the toolbar, menus and the row's context menu,
/// never as rows of their own.
struct FolderTreeRow<Tag: Hashable, Menu: View>: View {
    let url: URL
    var title: String?
    var systemImage = "folder"
    var startExpanded = false
    /// The List-selection tag for a folder (e.g. `BrowseSource.folder(url)` or just `url`).
    let tag: (URL) -> Tag
    /// Photos or folders dropped on the row (nil: not a drop target).
    var onDrop: ((URL, [URL]) -> Bool)?
    @ViewBuilder let menu: (URL) -> Menu

    @State private var isExpanded = false
    @State private var children: [URL]?
    @State private var isTargeted = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children ?? [], id: \.self) { child in
                FolderTreeRow(url: child, tag: tag, onDrop: onDrop, menu: menu)
            }
        } label: {
            Label(title ?? FileManager.default.displayName(atPath: url.path), systemImage: systemImage)
                .lineLimit(1)
                .help(url.path)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.3) : .clear))
                .modifier(DropTarget(url: url, onDrop: onDrop, isTargeted: $isTargeted))
                .contextMenu { menu(url) }
        }
        .tag(tag(url))
        .onAppear { if startExpanded { isExpanded = true } }
        .onChange(of: isExpanded, initial: true) { _, expanded in
            guard expanded, children == nil else { return }
            let folder = url
            Task {
                children = await Task.detached(priority: .userInitiated) { FolderScanner.subfolders(of: folder) }.value
            }
        }
    }
}

private struct DropTarget: ViewModifier {
    let url: URL
    let onDrop: ((URL, [URL]) -> Bool)?
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let onDrop {
            content.dropDestination(for: URL.self) { urls, _ in onDrop(url, urls) } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

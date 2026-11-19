import PhotoOrganizerCore
import SwiftUI

/// The keyword tree: the keyword list (Keywords.txt in the data folder) merged with keywords found on the loaded
/// photos. Checkboxes apply keywords to the selection; the filter button narrows the grid.
struct KeywordPanel: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(DataFolderModel.self) private var dataFolder
    let urls: [URL]
    @State private var newKeyword = ""
    @State private var search = ""

    var body: some View {
        let tree = filtered(KeywordNode.tree(from: dataFolder.keywords.paths + browser.loadedKeywords))
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("New keyword (Parent > Child)", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewKeyword)
                Button("Add", action: addNewKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(urls.isEmpty ? "Add to the keyword list" : "Add to the keyword list and the selected photos")
                Menu {
                    Button("Add Keywords in Use to List") { dataFolder.addKeywords(browser.loadedKeywords) }
                    Divider()
                    Button("Import Keyword List…") { dataFolder.importKeywordsInteractively() }
                    Button("Export Keyword List…") { dataFolder.exportKeywordsInteractively() }
                    Divider()
                    Button("Show Keywords.txt in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dataFolder.keywordsFile])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: dataFolder.keywordsFile.path))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)

            TextField("Find keyword", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            if tree.isEmpty {
                ContentUnavailableView("No Keywords", systemImage: "tag",
                                       description: Text("Add keywords above, or import a list from Lightroom or Bridge."))
            } else {
                List {
                    OutlineGroup(tree, children: \.children) { node in
                        KeywordRow(node: node, urls: urls, inKeywordList: dataFolder.keywords.contains(node.path))
                    }
                }
                .listStyle(.inset)
            }

            if urls.isEmpty, !tree.isEmpty {
                Text("Select photos to apply keywords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func addNewKeyword() {
        let paths = PhotoTags.parseKeywords(newKeyword)
        guard !paths.isEmpty else { return }
        dataFolder.addKeywords(paths)
        if !urls.isEmpty { browser.addKeywords(newKeyword, to: urls) }
        newKeyword = ""
    }

    /// Keeps nodes that match the search, plus their ancestors.
    private func filtered(_ nodes: [KeywordNode]) -> [KeywordNode] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            var copy = node
            let children = filtered(node.children ?? [])
            copy.children = children.isEmpty ? nil : children
            return node.name.localizedCaseInsensitiveContains(query) || !children.isEmpty ? copy : nil
        }
    }
}

private struct KeywordRow: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(DataFolderModel.self) private var dataFolder
    let node: KeywordNode
    let urls: [URL]
    let inKeywordList: Bool

    var body: some View {
        let count = urls.isEmpty ? 0 : browser.keywordCount(node.path, in: urls)
        let isFiltering = browser.criteria.keywords.contains { $0.caseInsensitiveCompare(node.path) == .orderedSame }
        HStack(spacing: 6) {
            Button {
                browser.toggleKeyword(node.path, for: urls)
            } label: {
                Image(systemName: count == 0 ? "square" : count == urls.count ? "checkmark.square.fill" : "minus.square.fill")
                    .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(urls.isEmpty)
            .help(urls.isEmpty ? "Select photos first" : "Apply to or remove from the selected photos")

            Text(node.name)
                .italic(!inKeywordList)
                .foregroundStyle(inKeywordList ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            Button {
                toggleFilter(isFiltering)
            } label: {
                Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFiltering ? Color.accentColor : .secondary)
            .help("Show only photos with this keyword")
        }
        .contextMenu {
            Button(isFiltering ? "Stop Filtering by Keyword" : "Filter by Keyword") { toggleFilter(isFiltering) }
            Divider()
            if inKeywordList {
                Button("Remove from Keyword List") { dataFolder.removeKeyword(node.path) }
            } else {
                Button("Add to Keyword List") { dataFolder.addKeyword(node.path) }
            }
        }
        .help(inKeywordList ? Keyword.display(node.path) : "\(Keyword.display(node.path)) (used on photos, not in your keyword list)")
    }

    private func toggleFilter(_ isFiltering: Bool) {
        if isFiltering {
            browser.criteria.keywords.removeAll { $0.caseInsensitiveCompare(node.path) == .orderedSame }
        } else {
            browser.criteria.keywords.append(node.path)
        }
    }
}

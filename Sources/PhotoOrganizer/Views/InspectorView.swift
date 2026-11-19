import PhotoOrganizerCore
import SwiftUI

struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", keywords = "Keywords", metadata = "Metadata"
        var id: String { rawValue }
    }

    @Environment(BrowserModel.self) private var browser
    @AppStorage("inspectorTab") private var tab: Tab = .info

    var body: some View {
        let urls = browser.selectedURLs
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()

            switch tab {
            case .keywords:
                KeywordPanel(urls: urls)
            case .info, .metadata:
                if urls.isEmpty {
                    ContentUnavailableView("No Selection", systemImage: "photo",
                                           description: Text("Select a photo to see its details."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if tab == .info {
                                if urls.count == 1, let photo = browser.primaryPhoto {
                                    PreviewImage(photo: photo)
                                } else {
                                    Text("\(urls.count) photos selected")
                                        .font(.title3.weight(.semibold))
                                }
                                TagEditor(urls: urls)
                                IPTCEditor(urls: urls)
                            } else if urls.count == 1, let photo = browser.primaryPhoto {
                                MetadataPanel(photo: photo, tags: browser.tags[photo.url])
                            } else {
                                Text("Select a single photo to see all of its metadata.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct PreviewImage: View {
    let photo: PhotoFile
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: photo) {
            image = await ThumbnailLoader.shared.image(for: photo.url, modified: photo.modified, maxPixelSize: 1600)
        }
    }
}

// MARK: - Rating, flag, label, keywords

private struct TagEditor: View {
    @Environment(BrowserModel.self) private var browser
    let urls: [URL]
    @State private var newKeywords = ""

    var body: some View {
        let all = urls.map { browser.tags[$0] ?? .empty }
        let ratings = Set(all.map { max($0.rating, 0) })
        let rating = ratings.count == 1 ? ratings.first : nil
        let labels = Set(all.map(\.label))
        let label = labels.count == 1 ? all.first?.label : nil
        let allPicked = all.allSatisfy(\.isPicked)
        let allRejected = all.allSatisfy(\.isRejected)
        let keywordCounts = keywordUsage(all)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                section("Rating") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                browser.setRating(rating == star ? 0 : star, for: urls)
                            } label: {
                                Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                                    .foregroundStyle(star <= (rating ?? 0) ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("\(star) star\(star == 1 ? "" : "s")")
                        }
                        if rating == nil {
                            Text("Mixed").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                        }
                    }
                    .font(.title3)
                }
                section("Flag") {
                    HStack(spacing: 8) {
                        Button {
                            if allPicked { browser.unflag(urls) } else { browser.pick(urls) }
                        } label: {
                            Image(systemName: allPicked ? "flag.fill" : "flag")
                                .foregroundStyle(allPicked ? .green : .secondary)
                        }
                        .help("Pick (P)")
                        Button {
                            if allRejected { browser.unflag(urls) } else { browser.reject(urls) }
                        } label: {
                            Image(systemName: allRejected ? "xmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(allRejected ? .red : .secondary)
                        }
                        .help("Reject (X)")
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                }
            }

            section("Label") {
                HStack(spacing: 8) {
                    ForEach(ColorLabel.allCases) { option in
                        Button {
                            browser.toggleLabel(option, for: urls)
                        } label: {
                            Circle().fill(option.color)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: label == option ? 2 : 0))
                                .opacity(label == nil || label == option ? 1 : 0.35)
                        }
                        .buttonStyle(.plain)
                        .help(option.rawValue)
                    }
                    if labels.count > 1 {
                        Text("Mixed").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            section("Keywords") {
                if !keywordCounts.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(keywordCounts, id: \.keyword) { item in
                            KeywordChip(keyword: item.keyword, isPartial: item.count < urls.count) {
                                browser.removeKeyword(item.keyword, from: urls)
                            }
                            .help(item.count < urls.count ? "On \(item.count) of \(urls.count) photos" : item.keyword)
                        }
                    }
                }
                TextField("Add keywords (comma-separated, > for levels)", text: $newKeywords)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        browser.addKeywords(newKeywords, to: urls)
                        newKeywords = ""
                    }
                    .textInputSuggestions {
                        ForEach(suggestions(excluding: keywordCounts.map(\.keyword)), id: \.self) { keyword in
                            Text(Keyword.display(keyword)).textInputCompletion(keyword)
                        }
                    }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    /// Union of keywords across the selection, with how many photos carry each.
    private func keywordUsage(_ all: [PhotoTags]) -> [(keyword: String, count: Int)] {
        var order: [String] = []
        var counts: [String: (display: String, count: Int)] = [:]
        for keyword in all.flatMap(\.keywords) {
            let key = keyword.lowercased()
            if counts[key] == nil { order.append(key); counts[key] = (keyword, 0) }
            counts[key]!.count += 1
        }
        return order.map { (counts[$0]!.display, counts[$0]!.count) }
    }

    private func suggestions(excluding existing: [String]) -> [String] {
        let typed = newKeywords.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty, !newKeywords.contains(",") else { return [] }
        let excluded = Set(existing.map { $0.lowercased() })
        let candidates = Set(browser.dataFolder.keywords.paths + browser.loadedKeywords)
        return candidates
            .filter { !excluded.contains($0.lowercased()) }
            .filter { $0.lowercased().hasPrefix(typed) || Keyword.leaf($0).lowercased().hasPrefix(typed) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(10)
            .map { $0 }
    }
}

private struct KeywordChip: View {
    let keyword: String
    let isPartial: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(Keyword.display(keyword)).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove keyword")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(isPartial ? 0.08 : 0.18)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isPartial ? 0.4 : 0), style: StrokeStyle(lineWidth: 1, dash: [3])))
        .opacity(isPartial ? 0.75 : 1)
    }
}

// MARK: - IPTC

private struct IPTCEditor: View {
    @Environment(BrowserModel.self) private var browser
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(IPTCField.allCases) { field in
                    GridRow {
                        Text(field.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        IPTCFieldEditor(field: field, urls: urls)
                    }
                }
            }
        }
    }
}

/// One editable IPTC field. Commits on Return or when focus leaves; shows "Mixed" when the
/// selected photos disagree.
private struct IPTCFieldEditor: View {
    @Environment(BrowserModel.self) private var browser
    let field: IPTCField
    let urls: [URL]
    @State private var text = ""
    /// The photos and value an in-progress edit started with, so a selection change that steals
    /// focus commits to the photos that were being edited, not the newly selected ones.
    @State private var editing: (urls: [URL], original: String?)?
    @FocusState private var isFocused: Bool

    private func common(for urls: [URL]) -> String? {
        let values = Set(urls.map { browser.tags[$0]?[field] ?? "" })
        return values.count == 1 ? values.first : nil
    }

    var body: some View {
        let common = common(for: urls)
        TextField(common == nil ? "Mixed" : "", text: $text, axis: field.isMultiline ? .vertical : .horizontal)
            .lineLimit(field.isMultiline ? 2...6 : 1...1)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .focused($isFocused)
            .onSubmit {
                commit()
                editing = (urls, self.common(for: urls))
            }
            .onChange(of: isFocused) { _, focused in
                if focused { editing = (urls, common) } else { commit() }
            }
            .onChange(of: urls, initial: true) {
                commit()
                text = self.common(for: urls) ?? ""
                if isFocused { editing = (urls, self.common(for: urls)) }
            }
            .onChange(of: common) { _, value in if !isFocused { text = value ?? "" } }
    }

    private func commit() {
        guard let editing else { return }
        self.editing = nil
        // Unchanged, or a "Mixed" field left empty (keeps the individual values): nothing to save.
        guard text != (editing.original ?? ""), !(editing.original == nil && text.isEmpty) else { return }
        browser.setField(field, to: text, for: editing.urls)
    }
}

// MARK: - Metadata

private struct MetadataPanel: View {
    let photo: PhotoFile
    let tags: PhotoTags?
    @State private var metadata: PhotoMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let metadata {
                Text("Info").font(.headline)
                MetadataGrid(entries: metadata.summary)

                Text("All Metadata").font(.headline).padding(.top, 4)
                ForEach(metadata.sections) { section in
                    DisclosureGroup {
                        MetadataGrid(entries: section.entries)
                            .padding(.top, 4)
                    } label: {
                        Text("\(section.title)  ").font(.subheadline.weight(.medium))
                            + Text("\(section.entries.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: MetadataKey(photo: photo, tags: tags)) {
            let url = photo.url
            metadata = await Task.detached(priority: .userInitiated) { MetadataReader.read(url) }.value
        }
    }

    private struct MetadataKey: Hashable {
        let photo: PhotoFile
        let tags: PhotoTags?
    }
}

private struct MetadataGrid: View {
    let entries: [MetadataEntry]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(entries) { entry in
                GridRow {
                    Text(entry.key)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 130, alignment: .trailing)
                    Text(entry.value)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption)
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

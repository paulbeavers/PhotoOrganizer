import AppKit
import PhotoOrganizerCore
import SwiftUI

/// Full-window review: a single large photo (loupe) or 2–4 photos side by side (compare).
///
/// Keys: ←/→ next/previous (loupe) or active pane (compare) · 0–5 rating · P/X/U pick/reject/unflag ·
/// 6–9 labels · Z zoom to 100% · F full screen · Return open in editor · Space/Esc close.
struct ReviewView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(EditorSettings.self) private var editors
    @FocusState private var isFocused: Bool
    @State private var zoomed = false
    @State private var activeIndex = 0

    private var isComparing: Bool { !browser.compareURLs.isEmpty }

    /// Photos on screen, in order.
    private var shown: [PhotoFile] {
        if isComparing { return browser.compareURLs.compactMap(browser.photo(for:)) }
        return browser.primaryPhoto.map { [$0] } ?? []
    }

    private var activeURL: URL? {
        let photos = shown
        guard !photos.isEmpty else { return nil }
        return photos[min(activeIndex, photos.count - 1)].url
    }

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, photo in
                    ReviewPane(photo: photo,
                               tags: browser.tags[photo.url],
                               zoomed: zoomed,
                               isActive: isComparing && index == activeIndex)
                        .onTapGesture {
                            if isComparing { activeIndex = index }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            activeIndex = 0
        }
        .onKeyPress(.escape) { close() }
        .onKeyPress(.space) { close() }
        .onKeyPress(.return) {
            if let activeURL { editors.open([activeURL]) }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let step = press.key == .leftArrow ? -1 : 1
            if isComparing {
                activeIndex = (activeIndex + step + shown.count) % shown.count
            } else {
                browser.moveSelection(by: step)
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZfF")) { press in
            if press.characters.lowercased() == "z" {
                zoomed.toggle()
            } else {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            return .handled
        }
        .onKeyPress(characters: CullingKeys.characters) { press in
            guard let activeURL else { return .ignored }
            // In compare mode tags go to the active pane; in loupe mode to the selection (with auto-advance).
            return CullingKeys.handle(press.characters, browser: browser, urls: isComparing ? [activeURL] : nil)
                ? .handled : .ignored
        }
    }

    private var toolbar: some View {
        @Bindable var browser = browser
        return HStack(spacing: 14) {
            Button {
                _ = close()
            } label: {
                Label("Done", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)

            if let activeURL, let photo = browser.photo(for: activeURL) {
                Text(photo.name).font(.headline).lineLimit(1)
                if !isComparing, let index = browser.displayedPhotos.firstIndex(where: { $0.url == activeURL }) {
                    Text("\(index + 1) of \(browser.displayedPhotos.count)")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(isComparing ? "Click a photo to make it active · ←/→ switch" : "←/→ next · P pick · X reject · 0–5 rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isComparing {
                Toggle("Auto-advance", isOn: $browser.autoAdvance)
                    .toggleStyle(.checkbox)
                    .help("Move to the next photo after rating or flagging")
            }
            Toggle(isOn: $zoomed) {
                Label("100%", systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
            }
            .toggleStyle(.button)
            .help("Zoom to actual pixels (Z)")
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Toggle full screen (F)")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    private func close() -> KeyPress.Result {
        browser.endReview()
        return .handled
    }
}

private struct ReviewPane: View {
    let photo: PhotoFile
    let tags: PhotoTags?
    let zoomed: Bool
    let isActive: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var preview: CGImage?
    @State private var full: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if zoomed, let full {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: full, scale: displayScale)
                            .frame(width: CGFloat(full.width) / displayScale, height: CGFloat(full.height) / displayScale)
                    }
                    .defaultScrollAnchor(.center)
                } else if let image = preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    ProgressView()
                }
                if zoomed, full == nil {
                    ProgressView("Loading full resolution…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: PreviewKey(photo: photo, size: Int(max(geometry.size.width, geometry.size.height) * displayScale))) {
                let size = max(512, Int(max(geometry.size.width, geometry.size.height) * displayScale))
                preview = await ThumbnailLoader.shared.image(for: photo.url, modified: photo.modified,
                                                            maxPixelSize: ((size + 511) / 512) * 512)
            }
            .task(id: zoomed ? photo : nil) {
                guard zoomed, full == nil else { return }
                full = await ThumbnailLoader.shared.fullImage(for: photo.url, modified: photo.modified)
            }
        }
        .overlay(alignment: .bottom) { badge }
        .overlay {
            Rectangle().strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3)
        }
        .onChange(of: photo) { full = nil }
    }

    private var badge: some View {
        HStack(spacing: 10) {
            if tags?.isRejected == true {
                Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            } else if tags?.isPicked == true {
                Label("Picked", systemImage: "flag.fill").foregroundStyle(.green)
            }
            let rating = max(tags?.rating ?? 0, 0)
            if rating > 0 {
                Text(String(repeating: "★", count: rating)).foregroundStyle(.orange)
            }
            if let label = tags?.label {
                Circle().fill(label.color).frame(width: 10, height: 10)
            }
            Text(photo.name).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
    }

    private struct PreviewKey: Hashable {
        let photo: PhotoFile
        let size: Int
    }
}

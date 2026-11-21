import PhotoOrganizerCore
import SwiftUI

/// The import window: pick a card or folder, choose photos (grouped by day), set options, import.
struct ImportView: View {
    @Environment(ImportModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SourceList()
                    .frame(width: 220)
                Divider()
                CandidateGrid()
                    .frame(minWidth: 370, maxWidth: .infinity)
                Divider()
                ImportOptions()
                    .frame(width: 310)
            }
            Divider()
            footer
        }
        // Fits inside the main window at its minimum size (960 × 600).
        .frame(minWidth: 900, minHeight: 560)
    }

    private var footer: some View {
        let plan = model.plan
        let days = Set(plan.groups.map(\.folder)).count
        return HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if plan.fileCount > 0 {
                Text("\(plan.fileCount) file\(plan.fileCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(plan.byteCount), countStyle: .file)) · into \(days) day folder\(days == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Button("Import") { model.startImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.fileCount == 0 || model.isImporting)
        }
        .padding(12)
    }
}

// MARK: - Sources

/// Cards and drives, then the home folder as a Finder-style tree: click a folder to import from it.
private struct SourceList: View {
    @Environment(ImportModel.self) private var model

    var body: some View {
        let selection = Binding<URL?>(
            get: { model.source?.items == nil ? model.source?.url : nil },
            set: { url in
                guard let url, url != model.source?.url else { return }
                if let volume = model.volumes.first(where: { $0.url == url }) {
                    model.select(volume)
                } else {
                    model.importFrom([url])
                }
            })

        VStack(alignment: .leading, spacing: 0) {
            Text("Import From").font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 8)
            List(selection: selection) {
                Section("Cards & Drives") {
                    if model.volumes.isEmpty {
                        Text("Insert a memory card or connect a camera.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.volumes) { volume in
                        Label(volume.name, systemImage: volume.hasDCIM ? "sdcard" : "externaldrive")
                            .lineLimit(1)
                            .help(volume.url.path)
                            .tag(volume.url)
                    }
                }
                Section {
                    ForEach(model.homeFolders, id: \.self) { folder in
                        FolderTreeRow(url: folder, tag: { $0 }) { _ in EmptyView() }
                    }
                } header: {
                    Label(FileManager.default.displayName(atPath: PortablePath.homeDirectory.path), systemImage: "house")
                }
            }
            .listStyle(.sidebar)

            Toggle("Include subfolders", isOn: Binding(
                get: { model.settings.includeSubfolders },
                set: { value in
                    model.option(\.includeSubfolders).wrappedValue = value
                    if model.source?.isVolume == false { model.scan() }
                }))
                .toggleStyle(.checkbox)
                .padding(12)
                .help("When importing from a folder, also import the photos in its subfolders")
        }
    }
}

// MARK: - Photos

private struct CandidateGrid: View {
    @Environment(ImportModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.source == nil {
                ContentUnavailableView("Choose a Source", systemImage: "sdcard",
                                       description: Text("Insert a memory card, connect a camera, or choose a folder of photos."))
            } else if model.isScanning {
                ProgressView("Reading photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.candidates.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("There are no photos here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 10)],
                              alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.days, id: \.day) { day in
                            Section {
                                ForEach(day.photos) { candidate in
                                    CandidateCell(candidate: candidate,
                                                  isSelected: model.selection.contains(candidate.url),
                                                  wasImported: model.alreadyImported.contains(candidate.url))
                                        .onTapGesture { model.toggle(candidate.url) }
                                }
                            } header: {
                                dayHeader(day.day, day.photos)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if let source = model.source {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.headline)
                    let imported = model.alreadyImported.count
                    Text("\(model.candidates.count) photos" + (imported > 0 ? " · \(imported) already imported" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.candidates.isEmpty {
                Button("New Only") { model.selectNewOnly() }
                    .help("Select every photo that hasn't been imported before")
                Button("All") { model.selectAll() }
                Button("None") { model.selectNone() }
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private func dayHeader(_ day: String, _ photos: [ImportCandidate]) -> some View {
        let selected = photos.filter { model.selection.contains($0.url) }.count
        return HStack {
            Text(day).font(.subheadline.weight(.semibold).monospacedDigit())
            Text("\(selected) of \(photos.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(selected == photos.count ? "Deselect Day" : "Select Day") {
                model.setDay(photos, selected: selected != photos.count)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}

private struct CandidateCell: View {
    let candidate: ImportCandidate
    let isSelected: Bool
    let wasImported: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .opacity(wasImported && !isSelected ? 0.4 : 1)
            .overlay(alignment: .topLeading) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.35))
                    .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                if wasImported {
                    Text("Imported")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(4)
                }
            }
            Text(candidate.name).font(.caption2).lineLimit(1).truncationMode(.middle)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
        .contentShape(Rectangle())
        .help(wasImported ? "\(candidate.name): imported before" : candidate.url.path)
        .task(id: candidate.url) {
            image = await ThumbnailLoader.shared.image(for: candidate.url, modified: candidate.captureDate, maxPixelSize: 256)
        }
    }
}

// MARK: - Options

private struct ImportOptions: View {
    @Environment(ImportModel.self) private var model

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Folders") {
                    Text("images/YYYY/yyyy-MM-dd/Imported").font(.callout.monospaced())
                }
                Text(PortablePath.string(model.imagesRoot))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if let first = model.plan.groups.first, let member = first.members.first {
                    LabeledContent("Example") {
                        Text("\(first.folder)/\(first.baseName).\(member.url.pathExtension)")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            Section("Files") {
                Picker("Import", selection: model.option(\.fileTypes)) {
                    ForEach(ImportFileTypes.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Rename files", isOn: model.option(\.renameFiles))
                if model.settings.renameFiles {
                    TextField("Template", text: model.option(\.nameTemplate))
                        .font(.callout.monospaced())
                    Text("{date:yyyyMMdd} · {n:4} · {time} · {camera} · {name}. RAW+JPEG pairs share a name; spaces become _.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Add to Every Photo") {
                TextField("Creator", text: model.option(\.creator))
                TextField("Copyright", text: model.option(\.copyright))
                TextField("Keywords", text: model.option(\.keywords), prompt: Text("Comma-separated, > for levels"))
            }

            Section("Copies") {
                Toggle("Verify every copy", isOn: model.option(\.verifyCopies))
                    .help("Re-read each copy from disk and compare its checksum with the original")
                Toggle("Also copy to a backup folder", isOn: model.option(\.backupEnabled))
                if model.settings.backupEnabled {
                    HStack {
                        Text(model.backupFolderURL.map { PortablePath.string($0) } ?? "No folder chosen")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { model.chooseBackupFolder() }
                    }
                }
            }

            Section("When Done") {
                Toggle("Eject the card", isOn: model.option(\.ejectWhenDone))
                    .disabled(model.source?.isVolume != true)
                Toggle("Open Import when a card is inserted", isOn: model.option(\.showOnCardInsert))
            }
        }
        .formStyle(.grouped)
    }
}

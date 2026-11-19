import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoOrganizerCore

/// Creates a scratch folder for each test.
private func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoOrganizerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a tiny JPEG, optionally with embedded XMP.
private func writeJPEG(to url: URL, embedded: CGImageMetadata? = nil) throws {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImageAndMetadata(destination, image, embedded, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite struct TagStoreTests {
    let store = TagStore()

    @Test func roundTripsTagsThroughSidecar() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("DSC_0001.jpg")
        try writeJPEG(to: photo)

        #expect(store.tags(for: photo) == .empty)

        try store.update(photo) {
            $0.rating = 4
            $0.label = .green
            $0.keywords = ["Iceland", "waterfall", " iceland "]
        }

        let sidecar = folder.appendingPathComponent("DSC_0001.xmp")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(store.tags(for: photo) == PhotoTags(rating: 4, label: .green, keywords: ["Iceland", "waterfall"]))

        let xml = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xml.contains("Rating"))
        #expect(xml.contains("Green"))
        #expect(xml.contains("waterfall"))

        try store.update(photo) {
            $0.rating = 0
            $0.label = nil
            $0.keywords.removeAll { $0 == "Iceland" }
        }
        #expect(store.tags(for: photo) == PhotoTags(rating: 0, label: nil, keywords: ["waterfall"]))
    }

    @Test func preservesForeignSidecarContent() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("DSC_0002.NEF")
        try Data().write(to: photo)  // contents irrelevant; only the sidecar is touched
        let sidecar = folder.appendingPathComponent("DSC_0002.xmp")
        let existing = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            crs:Exposure2012="+0.35"
            xmp:Label="Custom Workflow Label"
            xmp:Rating="2"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try existing.write(to: sidecar, atomically: true, encoding: .utf8)

        #expect(store.tags(for: photo).rating == 2)
        try store.update(photo) { $0.keywords = ["portfolio"] }

        let xml = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xml.contains("Exposure2012"))
        #expect(xml.contains("+0.35"))
        #expect(xml.contains("Custom Workflow Label"), "unrecognised labels must not be dropped")
        #expect(store.tags(for: photo) == PhotoTags(rating: 2, keywords: ["portfolio"]))
    }

    @Test func readsEmbeddedTagsAndCarriesThemIntoNewSidecar() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("IMG_0003.jpg")
        let embedded = CGImageMetadataCreateMutable()
        XMPTags.write(PhotoTags(rating: 3, keywords: ["camera"]), changedFrom: .empty, into: embedded)
        try writeJPEG(to: photo, embedded: embedded)

        #expect(store.tags(for: photo) == PhotoTags(rating: 3, keywords: ["camera"]))

        try store.update(photo) { $0.keywords.append("edited") }
        #expect(store.tags(for: photo) == PhotoTags(rating: 3, keywords: ["camera", "edited"]))
        let sidecar = Sidecar.readMetadata(at: Sidecar.url(for: photo))
        #expect(sidecar.map(XMPTags.read) == PhotoTags(rating: 3, keywords: ["camera", "edited"]))
    }

    @Test func noOpUpdateDoesNotCreateSidecar() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("IMG_0004.jpg")
        try writeJPEG(to: photo)
        try store.update(photo) { $0.rating = 0 }
        #expect(!FileManager.default.fileExists(atPath: Sidecar.url(for: photo).path))
    }
}

@Suite struct FolderScannerTests {
    @Test func listsOnlyImagesAndSubfolders() throws {
        let folder = try makeTempFolder()
        try writeJPEG(to: folder.appendingPathComponent("b.jpg"))
        try writeJPEG(to: folder.appendingPathComponent("a.JPG"))
        try Data().write(to: folder.appendingPathComponent("a.xmp"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        try Data().write(to: folder.appendingPathComponent("raw.NEF"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Selects"), withIntermediateDirectories: true)

        let names = try FolderScanner.photos(in: folder).map(\.name)
        #expect(names == ["a.JPG", "b.jpg", "raw.NEF"])
        #expect(FolderScanner.subfolders(of: folder).map(\.lastPathComponent) == ["Selects"])
    }
}

@Suite struct MetadataTests {
    @Test func readsSummaryAndSidecarSection() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("x.jpg")
        try writeJPEG(to: photo)
        try TagStore().update(photo) { $0.rating = 5 }

        let metadata = MetadataReader.read(photo)
        #expect(metadata.summary.contains { $0.key == "Dimensions" && $0.value == "8 × 8" })
        let sidecar = try #require(metadata.sections.first { $0.title == "XMP (Sidecar)" })
        #expect(sidecar.entries.contains { $0.key == "xmp:Rating" && $0.value == "5" })
    }
}

@Suite struct EditorTests {
    @Test func picksEditorByExtensionThenDefault() {
        let photoshop = ExternalEditor(name: "Photoshop", appURL: URL(fileURLWithPath: "/Applications/PS.app"))
        let nx = ExternalEditor(name: "NX Studio", appURL: URL(fileURLWithPath: "/Applications/NX.app"),
                                fileExtensions: ExternalEditor.parseExtensions("NEF, .nrw"))
        let editors = [photoshop, nx]
        #expect(preferredEditor(for: URL(fileURLWithPath: "/a/b.nef"), editors: editors, defaultID: photoshop.id) == nx)
        #expect(preferredEditor(for: URL(fileURLWithPath: "/a/b.jpg"), editors: editors, defaultID: photoshop.id) == photoshop)
        #expect(preferredEditor(for: URL(fileURLWithPath: "/a/b.jpg"), editors: editors, defaultID: nil) == nil)
    }
}

@Suite struct ExtendedTagTests {
    let store = TagStore()

    @Test func writesRejectPickHierarchyAndIPTCInAdobeFormat() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("DSC_0010.jpg")
        try writeJPEG(to: photo)

        try store.update(photo) {
            $0.keywords = ["Places > Iceland > Vík", "waterfall"]
            $0[.title] = "Skógafoss at dawn"
            $0[.caption] = "Line one\nLine two"
            $0[.creator] = "Paul"
            $0[.copyright] = "© 2026 Paul"
            $0[.city] = "Vík"
            $0[.country] = "Iceland"
            $0.pick()
        }
        let tags = store.tags(for: photo)
        #expect(tags.keywords == ["Places|Iceland|Vík", "waterfall"])
        #expect(tags[.title] == "Skógafoss at dawn")
        #expect(tags[.caption] == "Line one\nLine two")
        #expect(tags[.creator] == "Paul")
        #expect(tags[.copyright] == "© 2026 Paul")
        #expect(tags[.city] == "Vík")
        #expect(tags[.country] == "Iceland")
        #expect(tags.isPicked)

        let xml = try String(contentsOf: Sidecar.url(for: photo), encoding: .utf8)
        #expect(xml.contains("<lr:hierarchicalSubject>"))
        #expect(xml.contains("<rdf:li>Places|Iceland|Vík</rdf:li>"))
        #expect(xml.contains("<rdf:li>Iceland</rdf:li>"), "dc:subject carries every level for non-hierarchical apps")
        #expect(xml.contains("<rdf:li xml:lang=\"x-default\">Skógafoss at dawn</rdf:li>"))
        #expect(xml.contains("<photoshop:City>Vík</photoshop:City>"))

        try store.update(photo) { $0.reject() }
        let rejected = store.tags(for: photo)
        #expect(rejected.isRejected && !rejected.isPicked)
        #expect(try String(contentsOf: Sidecar.url(for: photo), encoding: .utf8).contains("<xmp:Rating>-1</xmp:Rating>"))

        try store.update(photo) { $0.rating = 3; $0[.title] = "" }
        let rated = store.tags(for: photo)
        #expect(rated.rating == 3 && !rated.isRejected)
        #expect(rated.fields[.title] == nil)
    }

    @Test func readsLightroomStyleSidecar() throws {
        let folder = try makeTempFolder()
        let photo = folder.appendingPathComponent("LR.NEF")
        try Data().write(to: photo)
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
        <dc:subject><rdf:Bag><rdf:li>Places</rdf:li><rdf:li>Iceland</rdf:li><rdf:li>sunset</rdf:li></rdf:Bag></dc:subject>
        <lr:hierarchicalSubject><rdf:Bag><rdf:li>Places|Iceland</rdf:li></rdf:Bag></lr:hierarchicalSubject>
        <dc:description><rdf:Alt><rdf:li xml:lang="x-default">From Lightroom</rdf:li></rdf:Alt></dc:description>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        try xmp.write(to: Sidecar.url(for: photo), atomically: true, encoding: .utf8)
        let tags = store.tags(for: photo)
        #expect(tags.keywords == ["Places|Iceland", "sunset"])
        #expect(tags[.caption] == "From Lightroom")
    }

    @Test func keywordMatching() {
        #expect(Keyword.matches("Places|Iceland|Vík", query: "Places|Iceland"))
        #expect(Keyword.matches("Places|Iceland|Vík", query: "iceland"))
        #expect(!Keyword.matches("Places|Iceland", query: "Places|Iceland|Vík"))
        #expect(!Keyword.matches("Iceland", query: "Places|Iceland"))
        #expect(Keyword.normalize(" Places > Iceland ›Vík ") == "Places|Iceland|Vík")
    }
}

@Suite struct FileOperationTests {
    private func makePair(in folder: URL, _ base: String, tagged: Bool = true) throws -> (raw: URL, jpg: URL) {
        let raw = folder.appendingPathComponent("\(base).NEF")
        let jpg = folder.appendingPathComponent("\(base).JPG")
        try Data("raw".utf8).write(to: raw)
        try writeJPEG(to: jpg)
        if tagged { try TagStore().update(raw) { $0.rating = 4 } }
        return (raw, jpg)
    }

    @Test func movingWholePairMovesSidecar() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let pair = try makePair(in: source, "DSC_1")
        let result = FileOperations.move([pair.raw, pair.jpg], to: destination)
        #expect(!result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC_1.xmp").path))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("DSC_1.xmp").path))
        #expect(TagStore().tags(for: destination.appendingPathComponent("DSC_1.NEF")).rating == 4)
    }

    @Test func movingHalfAPairCopiesSidecar() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let pair = try makePair(in: source, "DSC_2")
        _ = FileOperations.move([pair.jpg], to: destination)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("DSC_2.xmp").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC_2.xmp").path))
        #expect(TagStore().tags(for: pair.raw).rating == 4)
    }

    @Test func copyAvoidsOverwriting() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let pair = try makePair(in: source, "DSC_3")
        _ = FileOperations.copy([pair.raw], to: destination)
        let second = FileOperations.copy([pair.raw], to: destination)
        #expect(second.completed[pair.raw]?.lastPathComponent == "DSC_3-2.NEF")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC_3-2.xmp").path))
    }

    @Test func batchRenameKeepsPairsTogetherAndSwapsSafely() throws {
        let folder = try makeTempFolder()
        let a = try makePair(in: folder, "A")
        let b = try makePair(in: folder, "B", tagged: false)
        let date = { (_: URL) -> Date? in Date(timeIntervalSince1970: 1_700_000_000) }
        let plan = RenamePlan(urls: [a.raw, a.jpg, b.raw, b.jpg], template: "Trip_{date:yyyyMMdd}_{n:3}",
                              startNumber: 7, captureDate: date, cameraModel: { _ in "Z 8" })
        #expect(plan.problems.isEmpty)
        #expect(plan.items.map(\.newBaseName) == ["Trip_20231114_007", "Trip_20231114_008"])

        let result = FileOperations.rename(plan.items)
        #expect(!result.hasFailures)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Trip_20231114_007.JPG", "Trip_20231114_007.NEF", "Trip_20231114_007.xmp",
                          "Trip_20231114_008.JPG", "Trip_20231114_008.NEF"])

        // Swap two names.
        let x = folder.appendingPathComponent("Trip_20231114_007.NEF")
        let y = folder.appendingPathComponent("Trip_20231114_008.NEF")
        let swap = RenamePlan(urls: [y, x], template: "Trip_20231114_00{n}", startNumber: 7)
        #expect(swap.problems.isEmpty)
        #expect(!FileOperations.rename(swap.items).hasFailures)
    }

    @Test func renameDetectsCollisions() throws {
        let folder = try makeTempFolder()
        let a = try makePair(in: folder, "A", tagged: false)
        _ = try makePair(in: folder, "Existing", tagged: false)
        #expect(!RenamePlan(urls: [a.raw], template: "Existing").problems.isEmpty)
        #expect(!RenamePlan(urls: [a.raw, folder.appendingPathComponent("Existing.NEF")], template: "Same").problems.isEmpty)
    }
}

@Suite struct CollectionTests {
    @Test func criteriaMatching() {
        let tags = PhotoTags(rating: 4, isPicked: true, label: .red, keywords: ["Places|Iceland"], fields: [.title: "Black beach"])
        #expect(SearchCriteria(minimumRating: 3, label: .red, flag: .picked, keywords: ["iceland"]).matches(name: "a.jpg", tags: tags))
        #expect(SearchCriteria(text: "beach").matches(name: "a.jpg", tags: tags))
        #expect(!SearchCriteria(minimumRating: 5).matches(name: "a.jpg", tags: tags))
        #expect(!SearchCriteria(flag: .rejected).matches(name: "a.jpg", tags: tags))
        #expect(!SearchCriteria(minimumRating: 1).matches(name: "a.jpg", tags: PhotoTags(rating: -1)))
    }

    @Test func storeRoundTripsAndRenamesFiles() throws {
        let folder = try makeTempFolder()
        let store = CollectionStore(folder: folder)
        var collection = PhotoCollection(name: "Best of 2026", kind: .manual)
        collection.add([PortablePath.homeDirectory.appendingPathComponent("Pictures/a.NEF")])
        try store.save(collection)
        #expect(store.loadAll() == [collection])
        let json = try String(contentsOf: folder.appendingPathComponent("Best of 2026.json"), encoding: .utf8)
        #expect(json.contains("\"~/Pictures/a.NEF\""))

        collection.name = "Portfolio"
        try store.save(collection)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Portfolio.json"])

        let smart = PhotoCollection(name: "Five stars", kind: .smart, criteria: SearchCriteria(minimumRating: 5))
        try store.save(smart)
        #expect(store.loadAll().map(\.name) == ["Five stars", "Portfolio"])
        try store.delete(smart)
        #expect(store.loadAll().map(\.name) == ["Portfolio"])
    }

    @Test func relocatesMovedItems() {
        let old = URL(fileURLWithPath: "/Volumes/Photos/a.NEF"), new = URL(fileURLWithPath: "/Volumes/Photos/Selects/a.NEF")
        var collection = PhotoCollection(name: "x", kind: .manual)
        collection.add([old])
        let changed = collection.relocate([old: new])
        #expect(changed)
        #expect(collection.itemURLs == [new])
    }
}

@Suite struct KeywordListTests {
    @Test func parsesAndWritesLightroomFormat() {
        let text = "Places\n\tIceland\n\t\tVík\n\t\t{Vik}\n[People]\n\tAnna\nsunset\n"
        var list = KeywordList(text: text)
        #expect(list.paths == ["Places", "Places|Iceland", "Places|Iceland|Vík", "People", "People|Anna", "sunset"])
        list.add("Places|Norway|Lofoten")
        #expect(list.contains("places|norway"))
        #expect(list.text == "[People]\n\tAnna\nPlaces\n\tIceland\n\t\tVík\n\t\t\t{Vik}\n\tNorway\n\t\tLofoten\nsunset\n")
        list.remove("Places|Iceland")
        #expect(!list.contains("Places|Iceland|Vík"))
    }

    @Test func buildsTree() {
        let tree = KeywordNode.tree(from: ["b", "a|y", "a|x"])
        #expect(tree.map(\.name) == ["a", "b"])
        #expect(tree[0].children?.map(\.path) == ["a|x", "a|y"])
        #expect(tree[1].children == nil)
    }
}

@Suite struct RecursiveScanTests {
    @Test func scansSubfolders() throws {
        let folder = try makeTempFolder()
        let sub = folder.appendingPathComponent("Day 2")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeJPEG(to: folder.appendingPathComponent("1.jpg"))
        try writeJPEG(to: sub.appendingPathComponent("2.jpg"))
        #expect(try FolderScanner.photos(in: folder).map(\.name) == ["1.jpg"])
        #expect(try FolderScanner.photos(in: folder, recursive: true).map(\.name) == ["1.jpg", "2.jpg"])
    }
}

@Suite struct SharedSettingsTests {
    @Test func roundTripsThroughSettingsFile() throws {
        let folder = try makeTempFolder()
        let store = SharedSettingsStore(folder: folder)
        #expect(store.load() == nil)

        var settings = SharedSettings()
        settings.sidebarFolders = [PortablePath.string(PortablePath.homeDirectory.appendingPathComponent("Pictures")), "/Volumes/Photos"]
        let editor = ExternalEditor(name: "NX Studio", appURL: URL(fileURLWithPath: "/Applications/NX Studio.app"),
                                    fileExtensions: ["nef"], bundleIdentifier: "com.example.nx")
        settings.editors = [editor]
        settings.defaultEditorID = editor.id
        settings.autoAdvance = false
        try store.save(settings)

        #expect(store.load() == settings)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"~/Pictures\""))
        #expect(json.contains("\"/Volumes/Photos\""))
    }

    @Test func toleratesMissingKeysAndOldEditors() throws {
        let json = """
        {"sidebarFolders": ["~/Pictures"],
         "editors": [{"id": "6F1A3B9E-1C2D-4E5F-8A9B-0C1D2E3F4A5B", "name": "PS",
                      "appURL": "file:///Applications/PS.app", "fileExtensions": []}]}
        """
        let settings = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(settings.sidebarFolders == ["~/Pictures"])
        #expect(settings.editors.first?.bundleIdentifier == nil)
        #expect(settings.autoAdvance == true)
        #expect(settings.renameTemplate == SharedSettings().renameTemplate)
        #expect(settings.appearance == .system)
    }

    @Test func appearanceRoundTripsAndToleratesUnknownValues() throws {
        var settings = SharedSettings()
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"appearance\":\"dark\""))
        #expect(try JSONDecoder().decode(SharedSettings.self, from: data).appearance == .dark)

        let future = #"{"appearance": "sepia", "autoAdvance": false}"#
        let decoded = try JSONDecoder().decode(SharedSettings.self, from: Data(future.utf8))
        #expect(decoded.appearance == .system)
        #expect(decoded.autoAdvance == false)
    }
}

@Suite struct CompanionFileTests {
    /// Builds an NX Studio-style folder: DSC_1.NEF/.JPG, an XMP sidecar, NKSC_PARAM/DSC_1.NEF.nksc,
    /// and RawTherapee .pp3 files next to each photo.
    private func makeShoot(in folder: URL, _ base: String = "DSC_1") throws -> (raw: URL, jpg: URL) {
        let raw = folder.appendingPathComponent("\(base).NEF"), jpg = folder.appendingPathComponent("\(base).JPG")
        try Data("raw".utf8).write(to: raw)
        try writeJPEG(to: jpg)
        try TagStore().update(raw) { $0.rating = 3 }
        let nksc = folder.appendingPathComponent("NKSC_PARAM")
        try FileManager.default.createDirectory(at: nksc, withIntermediateDirectories: true)
        try Data("nx-edits".utf8).write(to: nksc.appendingPathComponent("\(base).NEF.nksc"))
        try Data("rt-raw".utf8).write(to: folder.appendingPathComponent("\(base).NEF.pp3"))
        try Data("rt-jpg".utf8).write(to: folder.appendingPathComponent("\(base).JPG.pp3"))
        return (raw, jpg)
    }

    private func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    @Test func locatesCompanionFiles() throws {
        let folder = try makeTempFolder()
        let shoot = try makeShoot(in: folder)
        #expect(Set(CompanionFileType.existing(for: shoot.raw).map(\.url.lastPathComponent)) == ["DSC_1.NEF.nksc", "DSC_1.NEF.pp3"])
        #expect(CompanionFileType.existing(for: shoot.jpg).map(\.url.lastPathComponent) == ["DSC_1.JPG.pp3"])
    }

    @Test func moveCarriesEditsIncludingNKSCFolder() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let shoot = try makeShoot(in: source)
        let result = FileOperations.move([shoot.raw, shoot.jpg], to: destination)
        #expect(!result.hasFailures)
        for path in ["DSC_1.NEF", "DSC_1.JPG", "DSC_1.xmp", "NKSC_PARAM/DSC_1.NEF.nksc", "DSC_1.NEF.pp3", "DSC_1.JPG.pp3"] {
            #expect(exists(destination, path), "\(path) should be at the destination")
            #expect(!exists(source, path), "\(path) should be gone from the source")
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("NKSC_PARAM/DSC_1.NEF.nksc")) == Data("nx-edits".utf8))
    }

    @Test func copyDuplicatesEdits() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let shoot = try makeShoot(in: source)
        _ = FileOperations.copy([shoot.raw], to: destination)
        #expect(exists(destination, "NKSC_PARAM/DSC_1.NEF.nksc"))
        #expect(exists(source, "NKSC_PARAM/DSC_1.NEF.nksc"))
        #expect(!exists(destination, "DSC_1.JPG.pp3"), "only the copied photo's edits travel")
    }

    @Test func copyAvoidsLeftoverEditsAtDestination() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let shoot = try makeShoot(in: source)
        // An orphaned NX Studio file for a photo that no longer exists at the destination.
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("NKSC_PARAM"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("NKSC_PARAM/DSC_1.NEF.nksc"))
        let result = FileOperations.copy([shoot.raw], to: destination)
        #expect(!result.hasFailures)
        #expect(result.completed[shoot.raw]?.lastPathComponent == "DSC_1-2.NEF")
        #expect(try Data(contentsOf: destination.appendingPathComponent("NKSC_PARAM/DSC_1-2.NEF.nksc")) == Data("nx-edits".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("NKSC_PARAM/DSC_1.NEF.nksc")) == Data("stale".utf8))
    }

    @Test func renameRenamesEdits() throws {
        let folder = try makeTempFolder()
        let shoot = try makeShoot(in: folder)
        let plan = RenamePlan(urls: [shoot.raw, shoot.jpg], template: "Trip_{n:3}")
        #expect(plan.problems.isEmpty)
        #expect(!FileOperations.rename(plan.items).hasFailures)
        for path in ["Trip_001.NEF", "Trip_001.JPG", "Trip_001.xmp", "NKSC_PARAM/Trip_001.NEF.nksc", "Trip_001.NEF.pp3", "Trip_001.JPG.pp3"] {
            #expect(exists(folder, path), "\(path) should exist after rename")
        }
        #expect(!exists(folder, "NKSC_PARAM/DSC_1.NEF.nksc"))
    }

    @Test func renameReportsEditCollisions() throws {
        let folder = try makeTempFolder()
        let shoot = try makeShoot(in: folder)
        try Data("other".utf8).write(to: folder.appendingPathComponent("NKSC_PARAM/Taken.NEF.nksc"))
        let plan = RenamePlan(urls: [shoot.raw], template: "Taken")
        #expect(plan.problems.contains { $0.contains("NX Studio") })
    }

    @Test func trashRemovesEdits() throws {
        let folder = try makeTempFolder()
        let shoot = try makeShoot(in: folder)
        let result = FileOperations.trash([shoot.raw])
        #expect(!result.hasFailures)
        #expect(!exists(folder, "NKSC_PARAM/DSC_1.NEF.nksc"))
        #expect(!exists(folder, "DSC_1.NEF.pp3"))
        #expect(exists(folder, "DSC_1.JPG.pp3"), "the JPEG's own edits stay")
        #expect(exists(folder, "DSC_1.xmp"), "the shared sidecar stays while the JPEG remains")
    }

    @Test func editorFoldersAreHiddenFromTheTree() throws {
        let folder = try makeTempFolder()
        _ = try makeShoot(in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Selects"), withIntermediateDirectories: true)
        #expect(FolderScanner.subfolders(of: folder).map(\.lastPathComponent) == ["Selects"])
        #expect(try FolderScanner.photos(in: folder, recursive: true).count == 2)
    }
}

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

        let sidecar = folder.appendingPathComponent("DSC_0001.jpg.xmp")  // non-RAW: per-file sidecar
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

    @Test func movingTheJPEGOfAPairLeavesTheRawSidecar() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let pair = try makePair(in: source, "DSC_2")
        try TagStore().update(pair.jpg) { $0.rating = 2 }
        let result = FileOperations.move([pair.jpg], to: destination)
        #expect(!result.hasFailures)
        // The RAW keeps its sidecar; the JPEG's own sidecar goes with it; nothing is shared.
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("DSC_2.xmp").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC_2.xmp").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC_2.JPG.xmp").path))
        #expect(TagStore().tags(for: pair.raw).rating == 4)
        #expect(TagStore().tags(for: destination.appendingPathComponent("DSC_2.JPG")).rating == 2)
    }

    @Test func movingABareLegacyJPEGTakesItsOldSidecar() throws {
        let source = try makeTempFolder(), destination = try makeTempFolder()
        let jpg = source.appendingPathComponent("OLD.jpg")
        try writeJPEG(to: jpg)
        try legacySidecar(rating: 5).write(to: source.appendingPathComponent("OLD.xmp"), atomically: true, encoding: .utf8)
        _ = FileOperations.move([jpg], to: destination)
        #expect(TagStore().tags(for: destination.appendingPathComponent("OLD.jpg")).rating == 5)
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("OLD.xmp").path))
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
        let json = try String(contentsOf: folder.appendingPathComponent("Best_of_2026.json"), encoding: .utf8)  // never spaces in file names
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
        #expect(settings.stackSameName, "stacking is on unless turned off")
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
        #expect(!exists(folder, "DSC_1.xmp"), "the RAW's sidecar goes with it: the JPEG has its own")
    }

    @Test func editorFoldersAreHiddenFromTheTree() throws {
        let folder = try makeTempFolder()
        _ = try makeShoot(in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Selects"), withIntermediateDirectories: true)
        #expect(FolderScanner.subfolders(of: folder).map(\.lastPathComponent) == ["Selects"])
        #expect(try FolderScanner.photos(in: folder, recursive: true).count == 2)
    }
}


/// A minimal sidecar as written before per-file sidecars (`<base>.xmp` for every file).
private func legacySidecar(rating: Int, keyword: String = "legacy") -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmp:Rating="\(rating)" crs:Exposure2012="+0.5">
    <dc:subject><rdf:Bag><rdf:li>\(keyword)</rdf:li></rdf:Bag></dc:subject>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """
}

@Suite struct PerFileSidecarTests {
    let store = TagStore()

    @Test func rawAndJPEGOfAPairHaveIndependentTags() throws {
        // The reported bug: labeling the JPEG of a RAW+JPEG pair also labeled the RAW.
        let folder = try makeTempFolder()
        let jpg = folder.appendingPathComponent("DSC_0370.JPG"), raw = folder.appendingPathComponent("DSC_0370.NEF")
        try writeJPEG(to: jpg)
        try Data("raw".utf8).write(to: raw)

        try store.update(jpg) { $0.label = .red }
        #expect(store.tags(for: jpg).label == .red)
        #expect(store.tags(for: raw).label == nil)

        try store.update(raw) { $0.rating = 5 }
        #expect(store.tags(for: raw) == PhotoTags(rating: 5))
        #expect(store.tags(for: jpg) == PhotoTags(label: .red))

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["DSC_0370.JPG", "DSC_0370.JPG.xmp", "DSC_0370.NEF", "DSC_0370.xmp"])
    }

    @Test func rawSidecarKeepsTheAdobeName() {
        #expect(Sidecar.url(for: URL(fileURLWithPath: "/p/DSC_1.NEF")).lastPathComponent == "DSC_1.xmp")
        #expect(Sidecar.url(for: URL(fileURLWithPath: "/p/IMG_1.CR3")).lastPathComponent == "IMG_1.xmp")
        #expect(Sidecar.url(for: URL(fileURLWithPath: "/p/DSC_1.JPG")).lastPathComponent == "DSC_1.JPG.xmp")
        #expect(Sidecar.url(for: URL(fileURLWithPath: "/p/a.tif")).lastPathComponent == "a.tif.xmp")
    }

    @Test func legacySidecarIsReadAndCarriedIntoTheNewOne() throws {
        let folder = try makeTempFolder()
        let jpg = folder.appendingPathComponent("OLD.jpg")
        try writeJPEG(to: jpg)
        try legacySidecar(rating: 3).write(to: folder.appendingPathComponent("OLD.xmp"), atomically: true, encoding: .utf8)
        #expect(store.tags(for: jpg) == PhotoTags(rating: 3, keywords: ["legacy"]))

        try store.update(jpg) { $0.label = .green }
        #expect(store.tags(for: jpg) == PhotoTags(rating: 3, label: .green, keywords: ["legacy"]))
        let xml = try String(contentsOf: folder.appendingPathComponent("OLD.jpg.xmp"), encoding: .utf8)
        #expect(xml.contains("Exposure2012"), "foreign content from the old sidecar is kept")
    }

    @Test func legacySidecarOfARawIsNotReadByItsJPEG() throws {
        let folder = try makeTempFolder()
        let jpg = folder.appendingPathComponent("DSC_9.JPG")
        try writeJPEG(to: jpg)
        try Data("raw".utf8).write(to: folder.appendingPathComponent("DSC_9.NEF"))
        try legacySidecar(rating: 4).write(to: folder.appendingPathComponent("DSC_9.xmp"), atomically: true, encoding: .utf8)
        #expect(store.tags(for: jpg) == .empty)
        #expect(store.tags(for: folder.appendingPathComponent("DSC_9.NEF")).rating == 4)
    }
}

@Suite struct ImportTests {
    /// A date in local time, like a camera clock.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func candidate(_ url: URL, _ when: Date, camera: String? = "NIKON Z 8") throws -> ImportCandidate {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ImportCandidate(url: url, size: size, captureDate: when, camera: camera)
    }

    /// A card-like folder: DCIM/100NZ_8/DSC_0001.NEF + .JPG (Jan 5), DSC_0002.JPG (Nov 19).
    private func makeCard() throws -> (root: URL, candidates: [ImportCandidate]) {
        let root = try makeTempFolder()
        let dcim = root.appendingPathComponent("DCIM/100NZ_8")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let raw = dcim.appendingPathComponent("DSC_0001.NEF"), jpg = dcim.appendingPathComponent("DSC_0001.JPG")
        let jpg2 = dcim.appendingPathComponent("DSC_0002.JPG")
        try Data(repeating: 7, count: 300_000).write(to: raw)
        try writeJPEG(to: jpg)
        try writeJPEG(to: jpg2)
        return (root, [try candidate(raw, date(2026, 1, 5, 9, 30)), try candidate(jpg, date(2026, 1, 5, 9, 30)),
                       try candidate(jpg2, date(2026, 11, 19, 14, 2, 7))])
    }

    @Test func layoutIsYearThenZeroPaddedDay() {
        #expect(ImportLayout.relativeFolder(for: date(2026, 1, 5)) == "2026/2026-01-05")
        #expect(ImportLayout.relativeFolder(for: date(2026, 11, 19)) == "2026/2026-11-19")
        #expect(ImportLayout.relativeFolder(for: date(2027, 3, 9, 23, 59)) == "2027/2027-03-09")
        #expect(ImportLayout.rootFolderName == "images")
    }

    @Test func namesNeverContainSpaces() {
        #expect(ImportLayout.noSpaces("My  Trip\tday 1") == "My_Trip_day_1")
        #expect(RenamePlan.sanitize(" Lake Day / 2 ") == "Lake_Day_-_2")
    }

    @Test func planKeepsPairsTogetherAndFiltersTypes() throws {
        let card = try makeCard()
        var settings = ImportSettings()
        let all = ImportPlan(candidates: card.candidates, settings: settings)
        #expect(all.groups.map(\.baseName) == ["DSC_0001", "DSC_0002"])
        #expect(all.groups.map(\.folder) == ["2026/2026-01-05/Imported", "2026/2026-11-19/Imported"])
        #expect(all.groups[0].members.count == 2)

        settings.fileTypes = .rawOnly
        #expect(ImportPlan(candidates: card.candidates, settings: settings).groups.flatMap(\.members).map(\.name) == ["DSC_0001.NEF"])
        settings.fileTypes = .nonRawOnly
        #expect(ImportPlan(candidates: card.candidates, settings: settings).fileCount == 2)

        settings.fileTypes = .all
        settings.renameFiles = true
        settings.nameTemplate = "{date:yyyyMMdd} Lake {n:3}"
        let renamed = ImportPlan(candidates: card.candidates, settings: settings)
        #expect(renamed.groups.map(\.baseName) == ["20260105_Lake_001", "20261119_Lake_002"], "spaces become _")
    }

    @Test func importCopiesVerifiesBacksUpAndTags() throws {
        let card = try makeCard()
        let data = try makeTempFolder(), backup = try makeTempFolder()
        let images = data.appendingPathComponent("images")
        // An already-rated RAW from a folder import: its sidecar and NX Studio edits come along.
        try TagStore().update(card.candidates[0].url) { $0.rating = 4 }
        let nksc = card.candidates[0].url.deletingLastPathComponent().appendingPathComponent("NKSC_PARAM")
        try FileManager.default.createDirectory(at: nksc, withIntermediateDirectories: true)
        try Data("edits".utf8).write(to: nksc.appendingPathComponent("DSC_0001.NEF.nksc"))

        var settings = ImportSettings()
        settings.creator = "Paul"
        settings.copyright = "© 2026 Paul"
        settings.keywords = "Lake, Places > Texas"
        let plan = ImportPlan(candidates: card.candidates, settings: settings)
        let result = Importer.run(plan, options: .init(imagesRoot: images, backupRoot: backup, settings: settings))
        #expect(result.failures.isEmpty)
        #expect(result.imported.map { $0.path.replacingOccurrences(of: images.path + "/", with: "") }
                == ["2026/2026-01-05/Imported/DSC_0001.NEF", "2026/2026-01-05/Imported/DSC_0001.JPG", "2026/2026-11-19/Imported/DSC_0002.JPG"])

        let day = images.appendingPathComponent("2026/2026-01-05/Imported")
        for name in ["DSC_0001.NEF", "DSC_0001.JPG", "DSC_0001.xmp", "DSC_0001.JPG.xmp", "NKSC_PARAM/DSC_0001.NEF.nksc"] {
            #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent(name).path), "\(name) imported")
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("2026/2026-01-05/Imported/\(name)").path), "\(name) backed up")
        }
        #expect(try Data(contentsOf: day.appendingPathComponent("DSC_0001.NEF")) == Data(contentsOf: card.candidates[0].url))

        let rawTags = TagStore().tags(for: day.appendingPathComponent("DSC_0001.NEF"))
        #expect(rawTags.rating == 4, "existing tags travel with the photo")
        #expect(rawTags[.creator] == "Paul" && rawTags[.copyright] == "© 2026 Paul")
        #expect(rawTags.keywords == ["Lake", "Places|Texas"])
        #expect(TagStore().tags(for: backup.appendingPathComponent("2026/2026-11-19/Imported/DSC_0002.JPG")).keywords == ["Lake", "Places|Texas"])

        #expect(result.history.count == 3)
        #expect(result.history[card.candidates[2].historyKey] == PortablePath.string(images.appendingPathComponent("2026/2026-11-19/Imported/DSC_0002.JPG")))
    }

    @Test func secondImportOfSameNamesDoesNotOverwrite() throws {
        let card = try makeCard()
        let images = try makeTempFolder().appendingPathComponent("images")
        let plan = ImportPlan(candidates: card.candidates, settings: ImportSettings())
        _ = Importer.run(plan, options: .init(imagesRoot: images, backupRoot: nil, settings: ImportSettings()))
        let again = Importer.run(plan, options: .init(imagesRoot: images, backupRoot: nil, settings: ImportSettings()))
        #expect(again.failures.isEmpty)
        #expect(again.imported.map(\.lastPathComponent) == ["DSC_0001-2.NEF", "DSC_0001-2.JPG", "DSC_0002-2.JPG"])
    }

    @Test func verificationCatchesACorruptCopy() throws {
        let folder = try makeTempFolder()
        let source = folder.appendingPathComponent("a.NEF"), target = folder.appendingPathComponent("b.NEF")
        try Data(repeating: 1, count: 10_000).write(to: source)
        try Importer.copyFile(from: source, to: target, verify: true)
        #expect(try Importer.sha256(of: target, bypassingCache: true) == Importer.sha256(of: source, bypassingCache: false))
        // Simulate corruption on disk: the digest of the copy no longer matches the original.
        try Data(repeating: 2, count: 10_000).write(to: target)
        #expect(try Importer.sha256(of: target, bypassingCache: true) != Importer.sha256(of: source, bypassingCache: false))
    }

    @Test func cancellingStopsBetweenFiles() throws {
        let card = try makeCard()
        let images = try makeTempFolder().appendingPathComponent("images")
        let plan = ImportPlan(candidates: card.candidates, settings: ImportSettings())
        let counter = Counter()
        let result = Importer.run(plan, options: .init(imagesRoot: images, backupRoot: nil, settings: ImportSettings()),
                                  isCancelled: { counter.value >= 1 }, onImported: { _, _ in counter.increment() })
        #expect(result.wasCancelled)
        #expect(result.imported.count == 1)
    }

    @Test func historyMergesAndScannerFindsCardPhotos() throws {
        let card = try makeCard()
        let found = ImportScanner.candidates(in: card.root)
        #expect(Set(found.map(\.name)) == ["DSC_0001.NEF", "DSC_0001.JPG", "DSC_0002.JPG"])

        let data = try makeTempFolder()
        let history = ImportHistory(dataFolder: data)
        try history.record(["a": "~/x"])
        try history.record(["b": "~/y"])
        #expect(history.load() == ["a": "~/x", "b": "~/y"])
    }

    @Test func scannerAcceptsFoldersAndIndividualPhotos() throws {
        let card = try makeCard()
        let loose = try makeTempFolder()
        let single = loose.appendingPathComponent("Single shot.jpg")
        try writeJPEG(to: single)
        try writeJPEG(to: loose.appendingPathComponent("not chosen.jpg"))
        let found = ImportScanner.candidates(from: [card.root, single, single])
        #expect(Set(found.map(\.name)) == ["DSC_0001.NEF", "DSC_0001.JPG", "DSC_0002.JPG", "Single shot.jpg"])
        #expect(found.count == 4, "a photo chosen twice is listed once")
    }

    @Test func importSettingsRoundTripInSettingsFile() throws {
        var settings = SharedSettings()
        settings.importOptions.renameFiles = true
        settings.importOptions.backupFolder = "/Volumes/Backup/Photos"
        settings.importOptions.includeSubfolders = false
        let decoded = try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.importOptions == settings.importOptions)
        let old = try JSONDecoder().decode(SharedSettings.self, from: Data(#"{"autoAdvance": true}"#.utf8))
        #expect(old.importOptions == ImportSettings())
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@Suite struct SmartRuleTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))!
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var heron: PhotoFacts {
        PhotoFacts(url: URL(fileURLWithPath: "/p/DSC_4470.NEF"),
                   tags: PhotoTags(rating: 4, isPicked: true, label: .green,
                                   keywords: ["Birds|Heron", "Brazos Bend"],
                                   fields: [.title: "Great blue heron", .city: "Needville", .country: "USA"]),
                   captureDate: day(2026, 1, 2), importDate: day(2026, 11, 17),
                   camera: "NIKON Z 8", lens: "NIKKOR Z 180-600mm f/5.6-6.3 VR")
    }

    private func check(_ field: SmartField, _ op: SmartOperator, _ value: String = "") -> Bool {
        SmartRule(field: field, op: op, value: value).matches(heron, now: now)
    }

    @Test func keywordsTextAndTags() {
        #expect(check(.keyword, .contains, "Birds"), "a parent keyword matches its children")
        #expect(check(.keyword, .contains, "heron"))
        #expect(!check(.keyword, .contains, "Sunset"))
        #expect(check(.keyword, .doesNotContain, "Sunset"))
        #expect(check(.keyword, .isNotEmpty) && !check(.keyword, .isEmpty))
        #expect(check(.anyText, .contains, "blue heron"))
        #expect(check(.fileName, .startsWith, "dsc_44"))
        #expect(check(.title, .contains, "heron") && !check(.caption, .isNotEmpty))
        #expect(check(.location, .contains, "needville"))
        #expect(check(.rating, .atLeast, "3") && !check(.rating, .atLeast, "5") && check(.rating, .equals, "4"))
        #expect(check(.flag, .is, "picked") && check(.flag, .isNot, "rejected"))
        #expect(check(.label, .is, "Green") && check(.label, .isNotEmpty) && check(.label, .isNot, "Red"))
        #expect(check(.fileType, .is, "raw") && check(.fileType, .isNot, "jpeg"))
        #expect(check(.camera, .is, "nikon z 8") && check(.lens, .contains, "180-600"))
    }

    @Test func rejectsAreNotLowRated() {
        let rejected = PhotoFacts(url: URL(fileURLWithPath: "/p/a.jpg"), tags: PhotoTags(rating: -1))
        #expect(!SmartRule(field: .rating, op: .atMost, value: "2").matches(rejected))
        #expect(SmartRule(field: .flag, op: .is, value: "rejected").matches(rejected))
        #expect(SmartRule(field: .fileType, op: .is, value: "jpeg").matches(rejected))
    }

    @Test func dates() {
        #expect(check(.captureDate, .on, "2026-01-02"))
        #expect(check(.captureDate, .before, "2026-01-03") && !check(.captureDate, .before, "2026-01-02"))
        #expect(check(.captureDate, .after, "2026-01-01") && !check(.captureDate, .after, "2026-01-02"))
        #expect(check(.importDate, .inLastDays, "7") && !check(.importDate, .inLastDays, "1"))
        #expect(!check(.captureDate, .inLastDays, "30"))
        let unknown = PhotoFacts(url: URL(fileURLWithPath: "/p/b.jpg"), tags: .empty)
        #expect(!SmartRule(field: .importDate, op: .inLastDays, value: "7").matches(unknown, now: now))
    }

    @Test func matchAllOrAny() {
        var rules = SmartRules(rules: [SmartRule(field: .rating, op: .atLeast, value: "5"),
                                       SmartRule(field: .keyword, op: .contains, value: "Birds")])
        #expect(!rules.matches(heron, now: now))
        rules.matchAll = false
        #expect(rules.matches(heron, now: now))
        #expect(SmartRules().matches(heron, now: now), "no rules: everything matches")
        #expect(rules.needsMetadata == false)
        rules.rules.append(SmartRule(field: .camera, op: .contains, value: "Z 8"))
        #expect(rules.needsMetadata)
    }

    @Test func oldSavedSearchesBecomeRules() {
        let old = SearchCriteria(text: "heron", minimumRating: 3, label: .green, flag: .notRejected, keywords: ["Birds"])
        let rules = SmartRules(criteria: old)
        #expect(rules.rules.map(\.field) == [.anyText, .rating, .label, .flag, .keyword])
        #expect(rules.matches(heron, now: now))
        let collection = PhotoCollection(name: "Old", kind: .smart, criteria: old)
        // Same conditions (each conversion gives the rules new IDs).
        #expect(collection.effectiveRules.rules.map { "\($0.field)|\($0.op)|\($0.value)" }
                == rules.rules.map { "\($0.field)|\($0.op)|\($0.value)" })
    }

    @Test func rulesRoundTripInCollectionFiles() throws {
        let folder = try makeTempFolder()
        let store = CollectionStore(folder: folder)
        let collection = PhotoCollection(name: "Herons", kind: .smart, folders: ["~/Pictures/Photo Organizer/images"],
                                         rules: SmartRules(matchAll: false, rules: [SmartRule(field: .keyword, op: .contains, value: "Birds|Heron"),
                                                                                     SmartRule(field: .importDate, op: .inLastDays, value: "30")]))
        try store.save(collection)
        #expect(store.loadAll() == [collection])
    }
}

@Suite struct ImportLogTests {
    @Test func savesLoadsNewestFirstAndIndexesDates() throws {
        let data = try makeTempFolder()
        let log = ImportLog(dataFolder: data)
        let older = ImportSession(started: Date(timeIntervalSince1970: 1_700_000_000), source: "NIKON Z 8", files: ["~/p/a.NEF", "~/p/b.NEF"])
        let newer = ImportSession(started: Date(timeIntervalSince1970: 1_700_090_000), source: "pabphoto", files: ["~/p/b.NEF", "~/p/c.jpg"])
        try log.save(older)
        try log.save(newer)
        #expect(log.loadAll() == [newer, older])
        let names = try FileManager.default.contentsOfDirectory(atPath: log.folder.path)
        #expect(names.allSatisfy { !$0.contains(" ") }, "no spaces in file names")

        let dates = ImportLog.importDates(log.loadAll())
        #expect(dates["~/p/a.nef"] == older.started)
        #expect(dates["~/p/b.nef"] == newer.started, "re-imported: the newest import wins")

        try log.delete(older)
        #expect(log.loadAll() == [newer])

        // A file for the same import under another name (saved in another time zone): saving keeps one.
        let foreign = log.folder.appendingPathComponent("2023-11-16_05-00-00_other.json")
        try FileManager.default.copyItem(at: log.folder.appendingPathComponent(try FileManager.default.contentsOfDirectory(atPath: log.folder.path)[0]), to: foreign)
        var moved = newer
        moved.files = ["~/p/Picked/b.NEF"]
        try log.save(moved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: log.folder.path).count == 1)
        #expect(log.loadAll() == [moved])
    }

    @Test func rebuildsEarlierImportsFromHistory() throws {
        let folder = try makeTempFolder()
        var history: [String: String] = [:]
        for name in ["a.jpg", "b.jpg"] {
            let url = folder.appendingPathComponent(name)
            try writeJPEG(to: url)
            history[name] = PortablePath.string(url)
        }
        history["gone"] = "/nonexistent/x.jpg"
        let sessions = ImportLog.reconstruct(history: history)
        #expect(sessions.count == 1)
        #expect(sessions[0].files.count == 2)
    }

    @Test func importTimeIsDateAddedNotTheOriginalPhotoDate() throws {
        // Importer.copyFile keeps the original modification date; macOS then moves the creation
        // date back too. The rebuilt import must still be dated "now", not when the photo was taken.
        let folder = try makeTempFolder()
        let source = folder.appendingPathComponent("src.jpg"), copy = folder.appendingPathComponent("copy.jpg")
        try writeJPEG(to: source)
        let taken = Date(timeIntervalSinceNow: -200 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: source.path)
        try Importer.copyFile(from: source, to: copy, verify: false)
        let session = try #require(ImportLog.reconstruct(history: ["k": PortablePath.string(copy)]).first)
        #expect(abs(session.started.timeIntervalSinceNow) < 120, "dated by when it was added, not \(taken)")
    }
}

@Suite struct CullFolderTests {
    /// A day folder with a RAW+JPEG pair in Imported (the RAW is a JPEG with a .NEF name: only the
    /// extension matters here), its sidecar and an NX Studio edit.
    private func makeDay() throws -> (day: URL, nef: URL, jpg: URL) {
        let day = try makeTempFolder().appendingPathComponent("2026-11-19")
        let imported = day.appendingPathComponent(CullFolders.imported)
        try FileManager.default.createDirectory(at: imported.appendingPathComponent("NKSC_PARAM"), withIntermediateDirectories: true)
        let nef = imported.appendingPathComponent("DSC_0370.NEF"), jpg = imported.appendingPathComponent("DSC_0370.JPG")
        try writeJPEG(to: nef)
        try writeJPEG(to: jpg)
        try TagStore().update(nef) { $0.pick() }
        try Data("edit".utf8).write(to: imported.appendingPathComponent("NKSC_PARAM/DSC_0370.NEF.nksc"))
        return (day, nef, jpg)
    }

    private func exists(_ day: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: day.appendingPathComponent(path).path)
    }

    @Test func pairStateAndFolders() throws {
        #expect(CullFolders.State(group: [PhotoTags(isPicked: true), .empty]) == .picked)
        #expect(CullFolders.State(group: [PhotoTags(rating: -1), .empty]) == .rejected)
        #expect(CullFolders.State(group: [.empty]) == CullFolders.State.none)
        #expect(CullFolders.State.none.folderName == "Imported")
        let (day, nef, _) = try makeDay()
        #expect(CullFolders.dayFolder(of: nef)?.lastPathComponent == day.lastPathComponent)
        #expect(CullFolders.dayFolder(of: day.appendingPathComponent("Picked/x.jpg")) != nil)
        #expect(CullFolders.dayFolder(of: day.appendingPathComponent("Other/x.jpg")) == nil)
    }

    @Test func pickingMovesThePairWithSidecarAndEdits() throws {
        let (day, nef, jpg) = try makeDay()
        let result = CullFolders.move([nef, jpg], to: .picked)
        #expect(result.failures.isEmpty)
        for path in ["Picked/DSC_0370.NEF", "Picked/DSC_0370.JPG", "Picked/DSC_0370.xmp", "Picked/NKSC_PARAM/DSC_0370.NEF.nksc"] {
            #expect(exists(day, path), "\(path)")
        }
        #expect(!exists(day, "Imported/DSC_0370.NEF") && !exists(day, "Imported/DSC_0370.xmp"))
        let pickedNEF = day.appendingPathComponent("Picked/DSC_0370.NEF")
        #expect(result.completed[nef]?.lastPathComponent == "DSC_0370.NEF")
        #expect(TagStore().tags(for: pickedNEF).isPicked, "tags travel with the photo")

        // Unflag: back to Imported, edits included.
        let back = CullFolders.move([pickedNEF, day.appendingPathComponent("Picked/DSC_0370.JPG")], to: .none)
        #expect(back.failures.isEmpty)
        #expect(exists(day, "Imported/DSC_0370.NEF") && exists(day, "Imported/NKSC_PARAM/DSC_0370.NEF.nksc"))
        #expect(!exists(day, "Picked/DSC_0370.NEF"))
        _ = jpg
    }

    @Test func exportsStayAndAreToldApart() throws {
        let (day, nef, jpg) = try makeDay()
        _ = CullFolders.move([nef, jpg], to: .picked)
        let picked = day.appendingPathComponent("Picked")
        let export = picked.appendingPathComponent("DSC_0370.TIF")
        try writeJPEG(to: export)
        let originals: Set<String> = ["DSC_0370.NEF", "DSC_0370.JPG"]
        let group = CullFolders.group(of: picked.appendingPathComponent("DSC_0370.NEF")) { originals.contains($0.lastPathComponent) }
        #expect(Set(group.originals.map(\.lastPathComponent)) == originals)
        #expect(group.exports.map(\.lastPathComponent) == ["DSC_0370.TIF"])

        _ = CullFolders.move(group.originals, to: .rejected)
        #expect(exists(day, "Rejected/DSC_0370.NEF") && exists(day, "Picked/DSC_0370.TIF"), "exports never move")
    }

    @Test func unknownPhotosMoveTogetherAndOutsidersStay() throws {
        let folder = try makeTempFolder()
        let loose = folder.appendingPathComponent("a.jpg")
        try writeJPEG(to: loose)
        #expect(CullFolders.move([loose], to: .picked).completed.isEmpty, "not in a day folder: stays")
        let (_, nef, _) = try makeDay()
        let group = CullFolders.group(of: nef) { _ in false }
        #expect(group.originals.count == 2 && group.exports.isEmpty)
    }

    @Test func importListFollowsMovedPhotos() {
        var session = ImportSession(source: "card", files: ["~/p/Imported/A.NEF", "~/p/Imported/B.NEF"])
        let moved = session.relocate([PortablePath.url("~/p/Imported/a.nef"): PortablePath.url("~/p/Picked/A.NEF")])
        #expect(moved && session.files == ["~/p/Picked/A.NEF", "~/p/Imported/B.NEF"])
    }

    @Test func scannerShowsALinkAsItsPhotoOnce() throws {
        let (day, nef, _) = try makeDay()
        let other = day.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("DSC_0370.NEF").path,
                                                   withDestinationPath: "../Imported/DSC_0370.NEF")
        let viaLink = try FolderScanner.photos(in: other)
        #expect(viaLink.map { $0.url.resolvingSymlinksInPath().path } == [nef.resolvingSymlinksInPath().path])
        #expect(try FolderScanner.photos(in: day, recursive: true).count == 2, "a photo and a link to it count once")
    }

    @Test func importsLandInImported() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10))!
        #expect(ImportLayout.destinationFolder(for: date) == "2026/2026-11-19/Imported")
    }
}

@Suite struct DataFolderMoveTests {
    /// A small data folder: a photo in a day's Picked folder, an empty Rejected folder, a
    /// collection, an import record, the import history and settings, all pointing inside it.
    private func makeDataFolder() throws -> (folder: URL, photo: URL) {
        let folder = try makeTempFolder().appendingPathComponent("Photo_Data")
        let day = folder.appendingPathComponent("images/2026/2026-11-19")
        try FileManager.default.createDirectory(at: day.appendingPathComponent("Picked"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day.appendingPathComponent("Rejected"), withIntermediateDirectories: true)
        let photo = day.appendingPathComponent("Picked/DSC_0001.JPG")
        try writeJPEG(to: photo)
        try TagStore().update(photo) { $0.rating = 5 }
        let path = PortablePath.string(photo)
        try CollectionStore(folder: folder.appendingPathComponent("Collections"))
            .save(PhotoCollection(name: "Best", kind: .manual, items: [path]))
        try ImportLog(dataFolder: folder).save(ImportSession(source: "card", files: [path]))
        try ImportHistory(dataFolder: folder).record(["k": path])
        var settings = SharedSettings()
        settings.sidebarFolders = [PortablePath.string(folder.appendingPathComponent("images")), "~/Elsewhere"]
        try SharedSettingsStore(folder: folder).save(settings)
        try "Birds\n".write(to: folder.appendingPathComponent("Keywords.txt"), atomically: true, encoding: .utf8)
        return (folder, photo)
    }

    private func checkMoved(to new: URL, from old: URL) throws {
        let photo = new.appendingPathComponent("images/2026/2026-11-19/Picked/DSC_0001.JPG")
        let path = PortablePath.string(photo)
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(TagStore().tags(for: photo).rating == 5, "sidecars come along")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("images/2026/2026-11-19/Rejected").path), "empty folders too")
        #expect(!FileManager.default.fileExists(atPath: old.path), "the emptied old folder is removed")
        #expect(CollectionStore(folder: new.appendingPathComponent("Collections")).loadAll().first?.items == [path])
        #expect(ImportLog(dataFolder: new).loadAll().first?.files == [path])
        #expect(ImportHistory(dataFolder: new).load()["k"] == path)
        let settings = try #require(SharedSettingsStore(folder: new).load())
        #expect(settings.sidebarFolders == [PortablePath.string(new.appendingPathComponent("images")), "~/Elsewhere"])
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Keywords.txt").path))
    }

    @Test func movesOnTheSameDiskAndRewritesPaths() throws {
        let (old, _) = try makeDataFolder()
        let new = try makeTempFolder().appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try DataFolderMove.run(from: old, to: new)
        try checkMoved(to: new, from: old)
    }

    @Test func copiesAndVerifiesAcrossDisks() throws {
        let (old, _) = try makeDataFolder()
        let new = try makeTempFolder().appendingPathComponent("Copied")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try DataFolderMove.run(from: old, to: new, alwaysCopy: true)
        try checkMoved(to: new, from: old)
    }

    @Test func cancellingLeavesTheOriginalUntouched() throws {
        let (old, photo) = try makeDataFolder()
        let new = try makeTempFolder().appendingPathComponent("Cancelled")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(throws: DataFolderMove.MoveError.cancelled) {
            try DataFolderMove.run(from: old, to: new, isCancelled: { true }, alwaysCopy: true)
        }
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(DataFolderMove.isEmpty(new), "partial copies are removed")
    }

    @Test func refusesUnsuitablePlaces() throws {
        let (old, _) = try makeDataFolder()
        #expect(throws: DataFolderMove.MoveError.sameFolder) { try DataFolderMove.validate(from: old, to: old) }
        #expect(throws: DataFolderMove.MoveError.insideCurrent) {
            try DataFolderMove.validate(from: old, to: old.appendingPathComponent("images"))
        }
        let full = try makeTempFolder()
        try Data("x".utf8).write(to: full.appendingPathComponent("note.txt"))
        #expect(throws: DataFolderMove.MoveError.notEmpty) { try DataFolderMove.validate(from: old, to: full) }
        #expect(DataFolderMove.isDataFolder(old) && !DataFolderMove.isDataFolder(full))
    }

    @Test func rebasesPortablePaths() {
        #expect(DataFolderMove.rebase("~/Pictures/Photo Organizer/images/a.jpg", from: "~/Pictures/Photo Organizer", to: "~/Dropbox/Photos")
                == "~/Dropbox/Photos/images/a.jpg")
        #expect(DataFolderMove.rebase("~/pictures/photo organizer", from: "~/Pictures/Photo Organizer", to: "/Volumes/X/P") == "/Volumes/X/P")
        #expect(DataFolderMove.rebase("~/Pictures/Photo Organizer 2/a.jpg", from: "~/Pictures/Photo Organizer", to: "~/X") == nil)
    }
}

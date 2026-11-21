import AppKit
import PhotoOrganizerCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dataFolder: DataFolderModel
    @State private var browser: BrowserModel
    @State private var editors: EditorSettings
    @State private var importer: ImportModel

    init() {
        // Used by scripts/build-app.sh to produce the .icns (renders and exits before any UI or data).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            AppIcon.writePNG(to: args[i + 1], size: 1024)
            exit(0)
        }
        let dataFolder = DataFolderModel()
        dataFolder.applyAppearance()  // before the first window appears
        let browser = BrowserModel(dataFolder: dataFolder)
        _dataFolder = State(initialValue: dataFolder)
        _browser = State(initialValue: browser)
        _editors = State(initialValue: EditorSettings(dataFolder: dataFolder))
        _importer = State(initialValue: ImportModel(dataFolder: dataFolder, browser: browser))
    }

    var body: some Scene {
        Window("Photo Organizer", id: "main") {
            ContentView()
                .environment(dataFolder)
                .environment(browser)
                .environment(editors)
                .environment(importer)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            PhotoCommands(browser: browser, editors: editors, importer: importer)
        }

        Settings {
            SettingsView()
                .environment(dataFolder)
                .environment(browser)
                .environment(editors)
                .environment(importer)
        }
    }
}

struct PhotoCommands: Commands {
    let browser: BrowserModel
    let editors: EditorSettings
    let importer: ImportModel

    private var hasSelection: Bool { !browser.selection.isEmpty }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Photos…") { importer.present() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(importer.isImporting)
            Divider()
            Button("New Collection…") {
                browser.namePrompt = NamePrompt(purpose: .newCollection(adding: browser.includingStacks(browser.selectedURLs)))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Smart Collection…") { browser.newSmartCollection() }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Button("New Folder…") {
                if let folder = browser.currentFolder { browser.namePrompt = NamePrompt(purpose: .newFolder(in: folder)) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(browser.currentFolder == nil)
            Button("Add Folder to Sidebar…") { browser.addRootFoldersInteractively() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Open in Editor") { editors.open(browser.selectedURLs) }
                .keyboardShortcut("o")
                .disabled(!hasSelection)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(browser.selectedURLs) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!hasSelection)
            Divider()
            Button("Rename…") { browser.renameRequest = FileRequest(urls: browser.includingStacks(browser.selectedURLs)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Move To…") { browser.transferInteractively(browser.selectedURLs, move: true) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Copy To…") { browser.transferInteractively(browser.selectedURLs, move: false) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Move to Trash…") { browser.trashRequest = FileRequest(urls: browser.includingStacks(browser.selectedURLs)) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
        }
        CommandGroup(before: .toolbar) {
            Button("Review / Compare") { browser.startReview() }
                .keyboardShortcut("y")
                .disabled(browser.visiblePhotos.isEmpty)
            Button(browser.includeSubfolders ? "Hide Subfolder Contents" : "Show Subfolder Contents") {
                browser.includeSubfolders.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Toggle("Stack Files with the Same Name", isOn: Binding(
                get: { browser.stacksEnabled }, set: { browser.stacksEnabled = $0 }))
            Button("Expand All Stacks") { browser.expandAllStacks() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!browser.stacksEnabled)
            Button("Collapse All Stacks") { browser.collapseAllStacks() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!browser.stacksEnabled)
            Divider()
            Button("Refresh") { browser.refresh() }
                .keyboardShortcut("r")
            Divider()
        }
        CommandMenu("Photo") {
            ForEach(0...5, id: \.self) { rating in
                Button(rating == 0 ? "No Rating" : String(repeating: "★", count: rating)) { browser.setRating(rating) }
                    .keyboardShortcut(KeyEquivalent(Character(String(rating))), modifiers: .command)
            }
            Divider()
            Button("Pick  (P)") { browser.pick() }
            Button("Reject  (X)") { browser.reject() }
                .keyboardShortcut(.delete, modifiers: .option)
            Button("Unflag  (U)") { browser.unflag() }
            Divider()
            ForEach(Array(ColorLabel.allCases.enumerated()), id: \.element) { index, label in
                Button(label.rawValue) { browser.toggleLabel(label) }
                    .keyboardShortcut(index < 4 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 6))), modifiers: .command) : nil)
            }
            Button("No Label") { browser.setLabel(nil) }
            Divider()
            Button("Select All Photos") { browser.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Select Rejected") {
                browser.selection = Set(browser.displayedPhotos.map(\.url).filter { browser.tags[$0]?.isRejected == true })
            }
            Button("Move Rejected to Trash…") {
                let rejected = browser.photos.map(\.url).filter { browser.tags[$0]?.isRejected == true }
                if !rejected.isEmpty { browser.trashRequest = FileRequest(urls: rejected) }
            }
        }
    }
}

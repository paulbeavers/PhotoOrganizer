# CLAUDE.md

Native macOS photo organizer (Bridge-style) that sits in front of file-based editors such as
Photoshop and NX Studio. SwiftUI app, Swift Package, macOS 15+, Swift 6 language mode.
See README.md for the feature list and the on-disk data formats.

## Commands

```sh
swift build                              # debug build
swift test                               # core unit tests (Swift Testing)
swift run                                # launch unsandboxed debug build
./scripts/build-app.sh                   # "build/Photo Organizer.app": release, sandboxed, signed
./scripts/build-app.sh --no-sandbox      # release without the sandbox
./scripts/package.sh                     # signed + notarized DMG → build/PhotoOrganizer-<date>-<commit>.dmg
./scripts/deploy-web.sh                  # publish web/ + DMG to https://photoorganizer.pbcs.io (needs `aws login`)
```

- Release: `package.sh` re-signs a copy in `build/package` with the Developer ID, hardened runtime
  and `Resources/PhotoOrganizer.entitlements`, notarizes and staples the app and then the DMG
  (notarytool profile `shoji-notary`, shared with ../shoji and ../mactile). Commit before packaging,
  or the build is stamped "(modified)".
- Website: `web/` (end users only, no developer content), published by `deploy-web.sh` to S3
  `photoorganizer-downloads-<account>` behind CloudFront. `deploy-cdn.sh` sets up the
  certificate, distribution and DNS once. Both are copies of ../mactile's. `index.html` keeps the
  `DOWNLOAD-URL` / `DOWNLOAD-SIZE` / `RELEASE-VERSION` placeholders; the deploy script fills them in.
- After any user-visible change, rebuild `build/Photo Organizer.app` (`./scripts/build-app.sh`) and
  relaunch it, because that is the copy the user runs.
- The app icon is drawn in code (`Services/AppIcon.swift`, rendered by `--render-icon`). After
  changing it, re-export `web/assets/photoorganizer-icon.png` (512 px) and `favicon.png` (64 px).

Run `swift test` after any change to `PhotoOrganizerCore`, and `swift build` after any change to the
app. Both should finish with no errors or warnings.

## Architecture

- `Sources/PhotoOrganizerCore/`: UI-free logic, covered by `Tests/PhotoOrganizerCoreTests`. Put
  anything testable here (XMP mapping, file operations, rename templates, collections, keyword
  parsing) rather than in the app target.
- `Sources/PhotoOrganizer/`: the SwiftUI app.
  - `Models/BrowserModel` is the central `@MainActor @Observable` state: browse source (folder or
    collection), photos, tags, selection, filters (`SearchCriteria`), culling, review state, file
    operations, and presentation requests (`namePrompt`, `renameRequest`, `trashRequest`), which
    `ContentView` presents.
  - `Models/DataFolderModel`: the data folder (`Settings.json`, collections JSON, `Keywords.txt`).
    Owns `settings: SharedSettings`; change it only via `updateSettings { }`, which saves immediately.
  - `Models/EditorSettings`: external editors and launching them.
  - `Services/`: `ThumbnailLoader` (memory + disk cache), `FileSystemWatcher` (FSEvents),
    `FolderAccess` (security-scoped bookmarks).

## Data rules (do not break)

- **Terminology:** never call the data folder a "library" or "catalog", in the UI, code or docs.
  The point of the app is that there is no catalog: just sidecars and a plain data folder.

- **Never modify original image files.** All tag writes go to XMP sidecars via `TagStore.update`,
  which writes only the fields that changed and preserves everything else in the sidecar (Camera Raw
  settings, other apps' fields).
- **One sidecar per photo** (`Sidecar.url(for:)`): RAW → `X.xmp` (Adobe convention); everything
  else → `X.JPG.xmp`. Never make files share tags again (that was a reported bug: labeling the
  JPEG of a pair also labeled the RAW). A non-RAW photo still *reads* a legacy `X.xmp` when no RAW
  shares the name (`Sidecar.legacyURL`). In file operations the shared `X.xmp` goes only with the
  photos that use it (`Group.usesSharedSidecar`); per-file `X.JPG.xmp` is a `CompanionFileType`.
- **Never put spaces in file or folder names the app creates.** `RenamePlan.sanitize` and
  `ImportLayout.noSpaces` turn whitespace into "_" (renames, imports, new folders, collection files).
- **Import** (`PhotoOrganizerCore/Import.swift`, `Models/ImportModel.swift`, `Views/ImportView.swift`):
  destination is always `<data folder>/images/YYYY/yyyy-MM-dd/Imported/` by capture date (`ImportLayout`).
- **Cull folders** (`PhotoOrganizerCore/CullFolders.swift`): picking / rejecting / unflagging a photo
  in a day's `Imported/`, `Picked/` or `Rejected/` *moves* it (pair together, via `FileOperations.move`,
  so sidecars and editor files travel) to the folder for its new state. Not symlinks: NX Studio
  ignores them. Not hard links: a synced data folder turns them into copies. The sidecar's flag is
  the record; `BrowserModel.updateTags` does the moves (`cullChanges`, `applyMoves`), and
  `DataFolderModel.relocate` keeps collections and the import log pointing at the files. Originals
  are the files in the import log; other same-name photos in `Picked/` are exports, which never
  move, and unpicking confirms before trashing them.
  `ImportPlan` groups same-name files so pairs share a new name; `Importer.run` copies with
  SHA-256 verification (re-read with F_NOCACHE), copies sidecars/editor files, writes import tags,
  then mirrors to the backup folder. `ImportHistory.json` (data folder) marks shots already imported.
  Import options live in `SharedSettings.importOptions`. The running import is saved to the import log
  at the start and shown as `.importSession(id)`, filling from `liveImportURLs` as files land.
- **Smart collections** (`PhotoOrganizerCore/SmartRules.swift`): `PhotoCollection.rules` (match all/any
  of `SmartRule`s); older collections' `criteria` are converted by `effectiveRules`. The browser
  applies rules live in `refilter()`; EXIF (camera/lens/capture date) and import dates are read into
  `ruleInfo` only when the open collection's rules need them. Editor: `Views/SmartCollectionEditor.swift`.
- **Import log** (`ImportLog.swift`): one `Imports/<yyyy-MM-dd_HH-mm-ss>_<id>.json` per import
  (shown under Collections → Imports, `BrowseSource.importSession`); imports from before the log
  are rebuilt once from `ImportHistory.json` by file creation time.
- Other editors' per-photo settings files (`CompanionFileType`: NX Studio `NKSC_PARAM/<file>.nksc`,
  RawTherapee `<file>.pp3`, DxO `<file>.dop`) must travel with their photo in every file operation.
  Any new file operation must handle them too (see `FileOperations`). For safety, a settings file is
  only renamed if its photo was.
- XMP must stay readable by Adobe apps: `xmp:Rating` (−1 = reject), `xmp:Label`, `dc:subject` (flat,
  every level) plus `lr:hierarchicalSubject` (`A|B|C`), and IPTC fields in their standard properties.
  The pick flag is the only app-specific field (`photoorganizer:Pick`).
- Collection files store paths under the home folder as `~/…` (`PortablePath`), so a synced data
  folder works on another Mac. Use `PortablePath.homeDirectory`, never `NSHomeDirectory()`, which points
  into the container when sandboxed.
- **All configuration goes in the data folder** (`SharedSettings` → `Settings.json`), so a synced
  data folder gives every Mac the same setup. Do not add new `UserDefaults`/`@AppStorage` settings.
  The only things allowed in local defaults: the data folder's own location, `FolderAccess` grants
  (security-scoped bookmarks are machine-specific), view state (last folder, inspector tab) and caches.
- Any new user-chosen location must be stored as a portable path in `Settings.json` *and* get a
  local access grant via `FolderAccess.rememberGrant`, so it works in the sandboxed build and on
  other Macs (where the user may need to grant access again).

## Gotchas learned the hard way

- **Alt-text XMP** (`dc:title`, `dc:description`, `dc:rights`): `CGImageMetadataTagCreate` with
  `.alternateText` serializes as empty. Write with
  `CGImageMetadataSetValueWithPath(m, nil, "dc:title[x-default]", value)`.
- Swift 6 rejects `static let` of `CFString` (it isn't Sendable). Use computed `static var`.
- `onKeyPress` handlers: check for disallowed modifiers
  (`press.modifiers.isDisjoint(with: [.command, .control, .option])`) rather than requiring
  `modifiers.isEmpty`, because digit keys can carry extra flags.
- Avoid ⌥⌘S and ⌃⌘S as shortcuts (the system sidebar toggle). `SidebarCommands()` and
  `InspectorCommands()` are installed in `PhotoOrganizerApp`.
- Stacks (same folder + base name): `BrowserModel.gridItems` / `displayedPhotos` are what the grid,
  navigation, selection ranges and review use; `visiblePhotos` is every matching file. Tags apply
  to the photo shown (per-file sidecars); file operations must go through
  `includingStacks(_:)` so a closed stack is never split.
- `BrowserModel.visiblePhotos` is cached and recomputed in `didSet` of `photos`, `tags`,
  `criteria` and the sort settings. Assign `tags` in bulk (build a copy, then assign once), not
  key by key in a loop.
- **Buttons on grid cells** (e.g. the stack arrow) must be added as an `.overlay` *after* the cell's
  tap / double-tap / drag gestures in `PhotoGridView`, never inside `PhotoCell`. Inside, SwiftUI's
  gesture arbitration intermittently gives the click to the cell (select / open in editor) and the
  button "sometimes does nothing". Keep such buttons inside the cell's bounds: the cell's
  `.contentShape(Rectangle())` clips hit-testing of anything sticking out.
- Inspector text fields must commit to the photos they started editing (see `IPTCFieldEditor`).
  Focus is lost *after* the selection has already changed.

## Testing the running app

UI changes can be checked by driving the app with System Events keystrokes and capturing **only
the app's window**: `screencapture -l <windowID>`, with the window ID looked up via
`CGWindowListCopyWindowInfo` and owner name `PhotoOrganizer` (`swift run`) or `Photo Organizer`
(app bundle). Never take full-screen captures, because they include the user's other windows.

- Use sample photos in a scratch folder, not the user's real Pictures folder.
- The unsandboxed debug binary reads settings from the defaults domain `PhotoOrganizer`. Point
  `lastFolder` (and `dataFolderBookmark`) at scratch locations for testing, then
  `defaults delete PhotoOrganizer` afterwards.

## Signing and the sandbox

`build-app.sh` signs with the Developer ID Application identity (else Apple Development). Dev
and release builds must share a team: the sandbox container and the saved bookmarks are tied to
the signature, and a build from another team triggers macOS's "access data from other apps"
prompt. Ad-hoc signing breaks them on every rebuild. Entitlements also grant **read-only** access to
`/Volumes/` (cards) and the home folder (the import window's folder tree) via temporary
exceptions, which is fine for Developer ID but would block a Mac App Store release. The import tree
must only list a folder's children when it's expanded, so merely opening Import never reads
Desktop / Documents / Downloads (that triggers macOS privacy prompts). The bundle ID is `io.pbcs.photoorganizer`
(it was `local.photoorganizer` before v0.3). The app is MIT licensed (`LICENSE`, bundled in the app). Entitlements are in
`Resources/PhotoOrganizer.entitlements`.

## Git

The default branch is `main`, and the remote is `git@github.com:paulbeavers/PhotoOrganizer.git`
(SSH). Commit or push only when asked.

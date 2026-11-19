# Photo Organizer

A native macOS photo browser that sits in front of file-based editors such as Photoshop and
NX Studio, in the spirit of Adobe Bridge. Photos stay where they are in the file system. Nothing
is imported, and originals are never modified. Everything the app records is stored in plain files:
XMP sidecars next to the photos, plus a library folder of JSON and text files.

## Features

**Browsing**
- Folders pinned in the sidebar, with lazily expanded subfolder trees. Drag a folder from Finder
  onto the sidebar to pin it.
- **Show subfolder contents** (⇧⌘D) flattens a whole tree into one grid.
- Live updates: folders are watched with FSEvents, so files that Photoshop saves appear right away.
- Thumbnails use the preview embedded in RAW and JPEG files and are **cached on disk** (trimmed
  automatically at 2 GB) so folders reopen instantly.

**Review and culling**
- **Space** opens a full-window loupe. With 2–4 photos selected it opens a **side-by-side compare**.
  **Z** zooms to 100% (full resolution) and **F** toggles full screen.
- **P** pick · **X** reject · **U** unflag · **0–5** rating · **6–9** labels. These work in the grid
  and in review. **Auto-advance** moves to the next photo after each decision.
- Filter by flag (Picked / Unflagged / Rejected / Hide Rejected), then use **Photo → Move Rejected
  to Trash…** to clean up.

**Metadata and tagging**
- Ratings, color labels and pick/reject flags.
- **Hierarchical keywords** (`Places > Iceland > Vík`). The **Keywords** inspector tab shows a keyword
  tree with checkboxes for the selection and a filter button on every keyword.
- **IPTC fields**: title, headline, caption, creator, copyright, sublocation, city, state and country.
  They can be edited for many photos at once; fields that differ show "Mixed".
- A metadata viewer listing every property ImageIO exposes: EXIF, TIFF, GPS, IPTC, maker notes,
  embedded XMP and sidecar XMP.

**Collections and saved searches**
- **Manual collections**: drag photos onto a collection in the sidebar, or use *Add to Collection*.
- **Smart collections**: set up filters (search text, rating, label, flag, keywords), then click
  *Save as Smart Collection…*. Opening one loads its filters into the filter bar, where they can be
  adjusted and saved again.

**File operations** (sidecars always travel with their photos)
- **Move / Copy To** a sidebar folder or any folder (⇧⌘M / ⇧⌘C). You can also drag photos onto a
  sidebar folder: plain drag moves, ⌥-drag copies.
- **Rename / batch rename** (⇧⌘R) with tokens such as `{name}`, `{n:4}`, `{date}`,
  `{date:yyyyMMdd}`, `{time}`, `{camera}` and `{folder}`, and a live preview with conflict checks.
  RAW+JPEG pairs get the same new name.
- **Move to Trash** (⌘⌫), **New Folder** (⌥⌘N).
- Manual collections are updated automatically when the app moves or renames their photos.

**External editors**
- Set a default editor and per-extension editors in Settings (⌘,), for example NEF → NX Studio and
  everything else → Photoshop. Photoshop and NX Studio are detected on first launch.
- Double-click, Return or ⌘O opens the photo in its editor. *Open With* lists every app that can
  open the file. Photos can also be dragged out of the grid into another app.

## Where data is stored

### Per photo: XMP sidecars

Sidecars follow the Adobe convention (`DSC_0001.NEF` → `DSC_0001.xmp`), so Camera Raw, Photoshop,
Bridge and Lightroom read the same data:

| Data | XMP property |
|---|---|
| Rating (−1 = rejected) | `xmp:Rating` |
| Color label | `xmp:Label` (Lightroom names; Bridge's "Select/Second/…" are read too) |
| Keywords | `dc:subject` (flat, every level) + `lr:hierarchicalSubject` (`Places\|Iceland`) |
| Title / Caption / Copyright | `dc:title` / `dc:description` / `dc:rights` (language alternatives) |
| Creator | `dc:creator` |
| Headline, City, State, Country | `photoshop:Headline`, `photoshop:City`, `photoshop:State`, `photoshop:Country` |
| Sublocation | `Iptc4xmpCore:Location` |
| Pick flag | `photoorganizer:Pick`. Adobe has no standard field for picks, so other apps ignore it. |

Rules for sidecars:
- Only fields you change are written. Everything else in a sidecar, such as Camera Raw develop
  settings, is preserved.
- If a photo has no sidecar, tags embedded in the image are shown, and the first edit copies them
  into a new sidecar.
- Files that share a base name (a RAW+JPEG pair) share one sidecar, as in Adobe's tools. If only part
  of a pair is moved, renamed or trashed, the sidecar is copied rather than moved, so the file left
  behind keeps its tags.

### Library folder

The default library folder is `~/Pictures/Photo Organizer Library`. It can be changed in
Settings → Library, for example to a synced folder shared between Macs.

```
Collections/<Name>.json   one file per collection (paths under your home folder are stored as ~/…)
Keywords.txt              keyword list in the tab-indented Lightroom/Bridge import/export format
```

### Not data

App preferences, the sidebar folder list (stored as security-scoped bookmarks) and editor settings
are kept in the app's user defaults. Thumbnails are a disposable cache in `~/Library/Caches`.

## Building

Requires Xcode 16 or later and macOS 15 or later.

```sh
swift run                              # build and launch unsandboxed (debug)
swift test                             # run the core tests
./scripts/build-app.sh                 # build/PhotoOrganizer.app: release, App Sandbox on
./scripts/build-app.sh --no-sandbox    # same, without the sandbox
open Package.swift                     # work in Xcode
```

The build script signs with the first *Apple Development* identity in your keychain (override with
`SIGN_IDENTITY=…`). A stable signature matters for the sandboxed build, because macOS ties the
app's data container and saved folder bookmarks to it.

**Sandbox notes.** The sandboxed app can only access `~/Pictures` and folders you choose in an open
panel or drag in. Those folders are remembered with security-scoped bookmarks. The sandboxed app
keeps its preferences in its own container, so the first sandboxed launch starts with a fresh
sidebar and editor list. Entitlements are in `Resources/PhotoOrganizer.entitlements`.

## Layout

```
Sources/PhotoOrganizerCore/     UI-free logic, unit tested (swift test)
  PhotoTags.swift               tag model, hierarchical keyword helpers, IPTC fields
  TagStore.swift                tags <-> XMP sidecars (diff-based, preserves foreign content)
  FileOperations.swift          copy/move/rename/trash with sidecars; batch rename templates
  Collections.swift             search criteria, collections, JSON collection store, portable paths
  KeywordLibrary.swift          Lightroom/Bridge keyword-list format and keyword trees
  FolderScanner.swift, MetadataReader.swift, ExternalEditor.swift
Sources/PhotoOrganizer/         SwiftUI app
  Models/                       BrowserModel (sources, selection, culling, file ops), LibraryModel, EditorSettings
  Services/                     ThumbnailLoader (memory + disk cache), FileSystemWatcher (FSEvents), FolderAccess (bookmarks)
  Views/                        sidebar, grid, inspector, keyword panel, review/compare, batch rename, settings
Resources/                      sandbox entitlements
scripts/build-app.sh            app bundle + signing
```

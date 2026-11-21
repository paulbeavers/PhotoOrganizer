# Photo Organizer

A native macOS photo browser that sits in front of file-based editors such as Photoshop and
NX Studio, in the spirit of Adobe Bridge. Photos stay where they are in the file system. Nothing
is imported, and originals are never modified. Everything the app records is stored in plain files:
XMP sidecars next to the photos, plus a data folder of JSON and text files. There is no
database or catalog.

## Features

**Importing** (File → Import Photos…, ⇧⌘I)
- **From a memory card, camera or any folder.** The import window shows connected cards and
  drives, and your home folder as a Finder-style tree: click a folder to import from it (with its
  subfolders, unless you turn that off). The window opens by itself when a card is inserted. Photos are listed by capture day, and ones imported before are greyed out and
  unchecked, even if they were imported on another Mac that shares the data folder.
- **Organized automatically** into the data folder: `images/YYYY/yyyy-MM-dd/Imported/`, by capture
  date (for example `images/2026/2026-11-19/Imported/`). File names never contain spaces.
- **Picked and Rejected folders:** picking a photo moves it (with its sidecar and editor edits)
  from the day's `Imported/` folder to `Picked/`, rejecting moves it to `Rejected/`, unflagging
  moves it back. Point NX Studio, Photoshop or any other editor at `Picked/` and you only see the
  keepers. A RAW+JPEG pair moves together. Exports made in `Picked/` stay there; unpicking asks
  before moving them to the Trash. Collections and the Imports list follow the photos.
- **Keep the camera's names or rename** with a template (`{date:yyyyMMdd}_{n:4}`…); RAW+JPEG
  pairs keep matching names.
- **RAW + JPEG, RAW only or JPEG only.**
- **Creator, copyright and keywords** added to every photo's sidecar as it arrives.
- **Verified copies:** every copy is re-read from disk and compared with the original by
  checksum. An optional **backup copy** goes to a second folder or drive in the same layout.
- **Cull while it copies:** the import appears at the top of Collections → Imports and the grid
  fills up as files land; progress and Cancel are on its entry. The card is ejected when the import finishes.

**Browsing**
- **Stacks.** Files with the same name in one folder (`DSC_0001.NEF` + `DSC_0001.JPG`) show as one
  stack with a badge such as "NEF+JPG". On top is the newest export (e.g. a TIFF you saved from NX
  Studio with the same name, so edited photos look edited), else the RAW; Settings → General →
  "On top of a stack" can always show the RAW instead. A faint slider mark after a file
  name means another app holds edits for it in its own settings files (Camera Raw, NX Studio,
  RawTherapee, DxO); previews show the camera's rendering, so hover to see which app. Picking, rejecting or unflagging an export
  on top also flags its originals. Click its arrow or press **S** to open it, and
  use View → Expand / Collapse All Stacks (⌥⌘→ / ⌥⌘←). Ratings, labels, flags and keywords apply to
  the photo you see (open the stack to tag the other file); moving, copying, renaming, trashing or
  adding a closed stack to a collection includes every file in it. Turn stacking off in View or
  Settings → General.
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
- **Smart collections** fill themselves from rules (File → New Smart Collection…, ⇧⌥⌘N). Match
  all or any of: keyword, rating, flag, label, file name, title, caption, creator, copyright,
  location, any text, file type (RAW, JPEG, HEIC…), camera, lens, capture date and import date
  ("in the last 7 days", on / before / after a date), searching every photo in the data folder and the sidebar folders.
  Camera and lens rules list the cameras and lenses found in your photos. The filter bar's *Save as Smart Collection…* starts one from the
  current search; right-click → *Edit Smart Collection…* changes it.
- **Imports**: every import is listed under Collections → Imports with its date, time, source and
  photo count, newest first.

**File operations** (sidecars and editor settings files always travel with their photos)
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

Every photo gets its own sidecar:

- **RAW files** use the Adobe convention, `DSC_0001.NEF` → `DSC_0001.xmp`, so Camera Raw,
  Photoshop, Bridge and Lightroom read the same data.
- **Other files** (JPEG, TIFF, PSD, HEIC…) use the full file name, `DSC_0001.JPG` →
  `DSC_0001.JPG.xmp`, as darktable and digiKam do. Adobe apps never read a separate sidecar for
  these formats, and this keeps the JPEG of a RAW+JPEG pair independent of the RAW.

The properties used:

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
- Each file of a RAW+JPEG pair has its own tags. Moving, renaming or trashing one file of a pair
  takes only that file's sidecar.
- Before v0.3.1 a JPEG used `<base>.xmp`. Such a sidecar is still read when no RAW file shares the
  name, and its contents are carried into `<file>.xmp` on the next edit.

### Other editors' settings files

Move, copy, rename and trash also carry each photo's settings files from other editors, so their
edits are never left behind or orphaned:

| Editor | Settings file |
|---|---|
| NX Studio | `NKSC_PARAM/<file>.nksc` (e.g. `NKSC_PARAM/DSC_0001.NEF.nksc`) |
| RawTherapee | `<file>.pp3` next to the photo |
| DxO PhotoLab | `<file>.dop` next to the photo |

These belong to one file each, so the NEF and JPEG of a pair keep their own. Editor folders such as
`NKSC_PARAM` are hidden from the sidebar. To support another editor, add it to
`CompanionFileType.all` in `FileOperations.swift`.

### Data folder

All app configuration and everything you create is saved in the data folder,
`~/Pictures/Photo Organizer` by default. It is an ordinary folder of files, not a database or
catalog. It can be changed in Settings → Data Folder. Put it in a synced folder (iCloud Drive,
Dropbox, a NAS) and every Mac gets the same sidebar, editors, preferences, collections and
keywords.

```
images/YYYY/yyyy-MM-dd/   one folder per capture day:
  Imported/               photos not culled yet, with their sidecars and edit files
  Picked/                 the picks (moved here), plus exports made here
  Rejected/               the rejects
Settings.json             sidebar folders, external editors, appearance, import options, preferences
Collections/<Name>.json   one file per collection (manual or smart, with its rules)
Imports/<date>.json       one file per import: when, from where, which photos
Keywords.txt              keyword list in the tab-indented Lightroom/Bridge import/export format
ImportHistory.json        which shots were imported, so cards aren't imported twice
```

Paths under your home folder are stored as `~/…`, so they work on another Mac with a different
user name. Editors also record the app's bundle ID, so they are found even if the app is installed
somewhere else. The app re-reads the data folder whenever it comes to the front, so synced changes
show up without a restart.

**Moving it:** Settings → Data Folder → Change…, then choose an empty folder and *Move Everything
Here*. Photos, collections, imports, keywords and settings move together, and the paths stored in
them are updated. On the same disk it takes a moment; on another disk every file is copied and
verified first, and the originals are removed only once everything has been copied (Cancel leaves
everything as it was). Choosing a folder that already is a data folder (e.g. synced from another
Mac) uses it as it is; *Start Fresh Here* starts an empty one with your settings.

### Kept on each Mac (not synced)

- **Where the data folder is.** The app needs this before it can read `Settings.json`.
- **Folder access permissions.** In the sandboxed build, folders outside `~/Pictures` need a
  one-time grant on each Mac (the sandbox's permission tokens can't be transferred). A sidebar
  folder without access shows a lock; click it to grant access.
- **View state:** the last folder opened and the inspector tab.
- **The thumbnail cache** in `~/Library/Caches`, which can be deleted at any time.

## Download

Get the signed, notarized app from **https://photoorganizer.pbcs.io**. It needs an Apple silicon
Mac running macOS 15 or later.

## Building

Requires Xcode 16 or later and macOS 15 or later.

```sh
swift run                              # build and launch unsandboxed (debug)
swift test                             # run the core tests
./scripts/build-app.sh                 # "build/Photo Organizer.app": release, App Sandbox on
./scripts/build-app.sh --no-sandbox    # same, without the sandbox
open Package.swift                     # work in Xcode
```

The build script signs with your *Developer ID Application* identity if you have one, else
*Apple Development*, else ad hoc (override with `SIGN_IDENTITY=…`). Development and release builds
must share a signing team, because macOS ties the sandboxed app's data container and saved folder
bookmarks to it.

## Releasing

```sh
./scripts/package.sh       # build/PhotoOrganizer-<date>-<commit>.dmg (+ build/PhotoOrganizer.dmg)
./scripts/deploy-web.sh    # publish web/ and the DMG to https://photoorganizer.pbcs.io
```

- `package.sh` signs a copy of the app with the Developer ID, hardened runtime and the sandbox
  entitlements, notarizes and staples it, then does the same for the drag-to-Applications DMG.
  It uses the `shoji-notary` notarytool profile (shared with Shoji and MacLucent), and
  `--unsigned` skips signing. Commit first: uncommitted builds are stamped "(modified)".
- `deploy-web.sh` uploads the site and the newest DMG to a private S3 bucket
  (`photoorganizer-downloads-<account>`) behind CloudFront, and invalidates the cache. It refuses
  to publish a DMG that isn't notarized. Needs `aws login`; `--dry-run` shows every AWS call.
- `deploy-cdn.sh` is a one-time setup: the ACM certificate, CloudFront distribution, bucket
  lock-down and Route 53 record for the hostname.

The scripts and the site are modelled on `../mactile` (MacLucent) and `../shoji`.

**Sandbox notes.** The sandboxed app can write only to `~/Pictures` (the default data folder) and
folders you choose in an open panel or drag in. For importing it may *read* mounted volumes (cards,
cameras) and the home folder; macOS still asks before Desktop, Documents and Downloads are read. Those folders are remembered with security-scoped bookmarks. The sandboxed app
keeps its preferences in its own container, so the first sandboxed launch starts with a fresh
sidebar and editor list. Entitlements are in `Resources/PhotoOrganizer.entitlements`.

## Layout

```
Sources/PhotoOrganizerCore/     UI-free logic, unit tested (swift test)
  PhotoTags.swift               tag model, hierarchical keyword helpers, IPTC fields
  TagStore.swift                tags <-> XMP sidecars (diff-based, preserves foreign content)
  FileOperations.swift          copy/move/rename/trash with sidecars; batch rename templates
  Collections.swift             search criteria, collections, JSON collection store, portable paths
  KeywordList.swift             Lightroom/Bridge keyword-list format and keyword trees
  FolderScanner.swift, MetadataReader.swift, ExternalEditor.swift
Sources/PhotoOrganizer/         SwiftUI app
  Models/                       BrowserModel (sources, selection, culling, file ops), DataFolderModel, EditorSettings
  Services/                     ThumbnailLoader (memory + disk cache), FileSystemWatcher (FSEvents), FolderAccess (bookmarks)
  Views/                        sidebar, grid, inspector, keyword panel, review/compare, batch rename, settings
Resources/                      Info.plist, sandbox entitlements
scripts/                        build-app.sh, package.sh (DMG), deploy-web.sh / deploy-cdn.sh (site)
web/                            the website (index.html, style.css, assets/)
```

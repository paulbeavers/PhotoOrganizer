# Roadmap: the shoot workflow

Goal: make it fast to **get a shoot off the card, cull it, and get to the good images**, the
real purpose of the app. Ideas from a planning discussion on 2026-11-18; nothing here is built
yet. ✅ marks what the app already does.

## 1. Getting photos in (import from a card)

The biggest gap: today files have to be copied with Finder first.

- **Import from card / camera:** detect a mounted card (`DCIM`), show its thumbnails, copy into
  the folder structure. Already-imported photos are greyed out (match by name + size + capture
  time, or a hash), so re-inserting a card offers only new shots.
- **Destination + naming templates**, e.g. `~/Photos/{yyyy}/{yyyy-MM-dd} {event}/` and
  `{date}_{n:4}`. Reuse `RenamePlan`'s token engine.
- **Verified copies** (checksum after copy) and an optional **second copy** to a backup drive /
  NAS during the same import, so the card can be wiped safely.
- **Tags on import:** creator, copyright, keywords written to every photo's sidecar on arrival.
- **RAW+JPEG choice:** import both, RAW only, or JPEG only.
- **Cull while copying:** photos appear in the grid as they land; eject the card when done.

## 2. Culling fast

✅ P / X / U flags, 0–5 ratings, auto-advance, loupe and 2–4-up compare, 100% zoom, stacks.

Speed and flow:
- **Prefetch** the next few full-size images into memory so the loupe never waits (large Z 8 NEFs).
- **Undo (⌘Z)** for flag/rating/label changes.
- **Progress:** "312 of 1,204 reviewed · 87 picks · 140 rejects", and a "next undecided" key.
- **Two-pass mode:** pass 1 pick/reject only (rejects disappear as you go); pass 2 rates just
  the picks. The filters exist; this packages them into a cull mode.

Bursts and similar shots:
- **Burst grouping by capture time** (e.g. frames < 1 s apart) as stacks, like RAW+JPEG stacks.
- **Burst view:** the whole burst side by side, choose the best frame, one key for
  "keep this one, reject the rest".
- **Similar-shot grouping** beyond bursts, using Vision image feature prints.

Checking sharpness:
- **Zoom to the focus point** if the camera records it (Nikon writes AF info in maker notes;
  check whether ImageIO exposes it).
- **Linked zoom/pan in compare** to judge the sharpest frame.
- **Histogram and clipping warnings** in the loupe.

Machine-assisted hints (suggestions to confirm, never automatic deletion):
- Likely blurry (focus / motion), eyes closed / face quality (Vision), badly over- or under-exposed.

## 3. Getting to the good images

✅ Filters by flag/rating, smart collections, open in Photoshop / NX Studio, move rejects to Trash.

- **A "Picks" view per shoot**, one click away.
- **"Move picks to Selects"** / move rejects to a `_Rejects` folder (reversible, unlike the Trash).
- **Open all picks** in NX Studio or Photoshop in one action.
- **Quick export for sharing:** resized JPEGs, optional watermark and copyright, to a folder or
  the share sheet.

## Suggested order

1. **Import from card**: templates, verified copies, backup copy, duplicate detection, tags on import.
2. **Cull mode**: prefetch, undo, progress, next-undecided, two-pass pick-then-rate.
3. **Bursts**: capture-time grouping and burst view with "keep one, reject the rest".
4. **Then** linked zoom, focus point, histogram, machine-assisted hints and export.

## Open questions for the user

- What is mostly shot: wildlife / sports / events (bursts matter most) or landscapes / travel?
  That decides how early bursts and blur/eye detection come in.
- How are cards imported today (card reader or camera over USB), and should a backup copy go to
  a second drive / NAS at import time?

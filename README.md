# QuickCull — prototype

A no-import, folder-native photo culling prototype for macOS. Point it at a
real shoot folder; thumbnails appear immediately from the cameras' embedded
JPEG previews — no catalog, no import, the directory stays the source of truth.

## Run it

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install` if
you don't have them).

```bash
cd QuickCull
swift run -c release
```

First build takes ~30 seconds; after that it launches in about a second.
(`-c release` matters — debug builds decode noticeably slower.)

macOS will ask permission the first time the app touches Pictures, Desktop,
Downloads or removable drives. That's normal TCC behavior for any
non-sandboxed app.

## Using it

Click a folder in the sidebar (or ⌘O to pick any folder). Then keyboard only:

| Key | Action |
|---|---|
| ← ↑ ↓ → | move through the grid |
| Space / Return | full-window preview |
| ← → (in preview) | previous / next frame |
| 1–5 | rate (and auto-advance, Photo Mechanic style) |
| 0 | clear rating |
| X | reject (and advance) |
| Space / Esc (in preview) | back to grid |

Ratings persist across launches (JSON in Application Support for now — XMP
sidecars are the production plan so ratings travel to Lightroom/Capture One).

RAW+JPEG pairs collapse to a single item badged `R+J`.

## What to benchmark (the whole point)

The status bar at the bottom reports two numbers when you open a folder:

1. **Folder read time** — shallow enumeration of the directory
2. **First thumbnail time** — file selected → pixels on screen

On a real shoot folder (1,000–5,000 RAWs), compare against Photo Mechanic:

- Time from clicking the folder to a usable contact sheet
- Scroll through the whole grid — any stutter?
- Arrow through full-screen previews as fast as you can tap — does the
  image ever lag behind the keystroke? (Neighbors are pre-decoded, so it
  shouldn't after the first frame.)

If the embedded-preview path is working, RAW previews should appear at
JPEG-like speed. If a folder feels slow, tell me the camera model — some
bodies embed only small previews and need the per-camera extraction work
that's on the roadmap.

## What's deliberately NOT here yet

This is a spike to validate the two claims that matter (no-import UX,
no-lag pipeline). Missing, by design, roughly in build order:

- XMP sidecar read/write (Lightroom/Capture One round-trip)
- Disk thumbnail cache keyed on file identity (currently memory-only per run)
- Full-size embedded JPEG extraction per camera model — DONE for Canon CR3
  (CR3PreviewExtractor pulls the 6000×4000 track-1 JPEG directly from the
  container; verified against EOS R3 files). Other formats still use
  ImageIO's embedded preview.
- Filter bar (show only ★≥3, hide rejects), color labels UI
- FSEvents folder watching, move-to-trash for rejects, rename/move
- Metadata inspector column (EXIF/histogram — see the HTML mockup)
- 100% zoom with tiled rendering

## Architecture map

```
main.swift                 app bootstrap (no nib/storyboard → runs via swift run)
AppDelegate.swift          window + menu
MainSplitViewController    sidebar | grid split, preview overlay host
FolderSidebar.swift        lazy NSOutlineView directory tree (Places + Drives)
PhotoAsset.swift           shallow folder scan, RAW+JPEG pairing
ThumbnailLoader.swift      ★ the pipeline: embedded-preview-first ImageIO decode,
                           priority queue, cancellation, NSCache
PhotoGridViewController    NSCollectionView contact sheet + prefetch + cull keys
PreviewOverlay.swift       full-window preview, neighbor pre-decode
RatingsStore.swift         optimistic in-memory culls, debounced JSON persistence
```

Everything maps 1:1 onto the production architecture we discussed — swap the
JSON store for XMP + SQLite cache, add FSEvents, and this skeleton grows up
rather than getting thrown away.

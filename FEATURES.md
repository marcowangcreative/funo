# f/uno — Features

*The fastest first pass in photography. No import. No catalog. The folder is the catalog.*

## Open & browse
- **Instant open** — click any folder and the grid appears immediately. No import step, no indexing wait, no database build. Thumbnails stream in from embedded previews.
- **Folder-native** — your folder structure *is* the organization. Browse drives and folders in the sidebar exactly as they exist on disk, local or external.
- **Tabs, browser-style** — multiple contact sheets open at once. ⌘T new tab, ⌘W close, ⌘1–9 jump, ⌘←/→ cycle. Background tabs freeze (zero work) until activated.
- **RAW+JPEG pairing** — same-name pairs collapse to one grid item, badged R+J.
- **CR3-aware decoding** — full-resolution embedded JPEGs pulled straight from Canon CR3s. External drives get dedicated decode lanes; memory cards are treated gently.

## Cull
- **Keyboard-first rhythm** — 1–5 stars, ⌃1–5 color labels, X reject, 0 clear. In expanded view every rating auto-advances to the next frame.
- **Color-first mode** — press ` to flip the scheme: 1–5 become color labels, ⌃1–5 become stars. For color-driven workflows.
- **Lightroom-matched filtering** — star threshold with at least / exactly / at most, color-label filters including "no label," rejects view. Same vocabulary, zero translation.
- **Expanded view** — full-window preview with Z to 100%, scroll-wheel zoom, drag pan. Resizable filmstrip with ratings and labels on every frame. RGB histogram with clipping warnings, full EXIF.
- **Survey mode** — S compares 2–4 selected frames side by side with *synchronized zoom*: scroll on any frame and all frames zoom to the same spot. The sharpest frame wears the crown.
- **Selection-scoped review** — select ten photos, hit Space, and expanded view contains exactly those ten. The filmstrip and arrows never leave your working set.

## See what the camera saw
- **Face triage** — every face in the frame, cropped and graded: green eyes-open, amber squinting-check, red eyes-closed. Blink detection is smile-aware — a laughing kid doesn't torpedo the frame. Click any face to zoom the preview to it, 1:1.
- **Group-shot rescue** — small faces in big groups get a second high-resolution analysis pass, so back-row eyes are graded from real detail, not noise.
- **Focus score** — sharpness measured on the *subject's face*, not the whole frame. A tack-sharp portrait against creamy bokeh scores high; a busy back-focused frame doesn't fake its way to "crisp."
- **All on-device** — every analysis runs locally. Your photos never leave your Mac.

## Files, safely
- **Originals are never touched** — ratings and labels write to standard XMP sidecars. Lightroom, Capture One, and Photo Mechanic read them natively; culls made elsewhere are adopted on open. Foreign sidecars are never overwritten.
- **Finder-grade file ops** — ⌘C/⌘X/⌘V copy, cut, and paste photos between folders (sidecars travel too). Drag selections onto sidebar folders to move. Copies and moves carry their ratings. Everything undoable.
- **Rejects go to the Trash** — never deleted in place. Rename in-grid. Rotate losslessly ([ and ]).
- **Card ingest** — memory cards are read-only to f/uno. Ingest *copies* to your drive with folder templates; the card is never modified.
- **Folder templates** — one click builds your standard shoot structure (RAW / selects / exports / …) exactly the way you like it.

## Hand off
- **→ Lightroom** — selected photos open in Lightroom's import dialog, pre-selected, ratings and labels intact via XMP.
- **→ Photoshop** — selects open directly in Photoshop (auto-discovered installation).

## Built like an instrument
- Native AppKit on Apple Silicon and Intel. A ~2 MB app that opens 2,000-RAW folders while catalog apps are still spinning.
- Dark, engraved, keyboard-labeled interface. The brand shows up when there's no work on screen, then gets out of the way.

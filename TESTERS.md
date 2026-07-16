# QuickCull Beta 0.9

A fast, no-import photo culling app for Mac. Your folders ARE the library —
open a folder and start rating. Nothing is imported, nothing is cataloged,
and your RAW files are never modified.

## Install

1. Unzip `QuickCull-0.9.0-beta.zip` and drag **QuickCull.app** to Applications.
2. First launch: **right-click the app → Open → Open**. (The beta isn't
   notarized with Apple yet, so double-clicking shows a warning once.
   Right-click → Open bypasses it; after that it opens normally.)
3. macOS will ask permission the first time QuickCull touches Desktop,
   Downloads, Pictures, or a memory card. Say yes — it's browsing in place.

## The 5-minute tour

- Click any folder in the sidebar. Photos appear immediately — that's the
  whole point. No import step exists. (⌘[ / ⌘] quietly walk your folder
  history, browser-style, if your hands want it.)
- Filters never lose photos: when a star/color filter is hiding some, an
  amber strip says "Showing X of Y — Show All ✕". One click brings
  everything back. File moves/renames/trash show a clickable **Undo** in
  the status bar (⌘Z works too).
- **Arrow keys** move · **1–5** rate · **6–9** color label · **X** reject ·
  **Space** opens full screen · **Z** true 100% zoom · **Esc** back.
- In full screen: the right rail shows histogram + EXIF (**I** toggles) and
  every detected face graded green/amber/red (**F** toggles); **Tab** shows
  or hides the whole rail at once. Click a face to zoom straight to it.
  Red ring = someone's blinking. Drag the handle between the two cards to
  give one more room.
- **Survey**: select 2–4 similar frames and press **S** — they go up side
  by side. Arrows move the amber focus ring, 1–5/X rate or reject the
  focused frame, Space opens it full screen, Esc returns to the grid. A
  focus meter under each frame compares sharpness and crowns the sharpest —
  best for near-identical shots of the same pose. (Expanded view also shows
  a Focus % in the INFO panel.)
- Drag photos onto any folder in the sidebar to move them (RAW+JPEG pairs
  and metadata travel together). **⌘C/⌘X/⌘V also work on photos**: copy or
  cut a selection, navigate anywhere (even another tab), paste — cut moves,
  copy duplicates, and pairs + sidecars always travel together.
- Done culling? The **→ Lightroom** and **→ Photoshop** buttons in the
  bottom-right send the selected photos straight over (they only appear if
  the app is installed). Right-click folders for templates — try
  "Apply Template → Wedding" on a job folder.
- **Tabs, like a browser**: ⌘-click a sidebar folder to open it as a second
  contact sheet — each tab keeps its own scroll spot, selection and filter.
  The tab bar works like a browser: a **+** button adds a tab, ⌘T opens a
  blank one, ⌘W closes one, **⌘→ / ⌘← switch tabs**, ⌘1–⌘8 jump, ⌘9 = last,
  drag tabs to reorder. One folder = one tab: opening a folder that's
  already open just switches to its tab.
 Background tabs are frozen (they cost
  nothing), so open as many as the job needs.
- **⌘I ingests memory cards**: pick card sections, a job name, a template —
  culling starts while the card is still copying.
- Ratings and color labels are written as standard XMP sidecars: import the
  folder into Lightroom/Photo Mechanic/Capture One and your culls are there.

## What to know

- Rejecting (X) only marks a photo. Actually deleting is ⌘⌫ → macOS Trash
  (recoverable). Moves/renames support ⌘Z undo.
- Cards are read-only to QuickCull — ingest copies, never moves.
- **f/uno is free for 14 days from your first launch.** After that it asks
  for a license to keep culling — $99, or $79 with the founders code
  `FUNODERS` (first 100 licenses). One purchase, yours forever, 2 Macs,
  all 1.x updates included.
- First browse of a big folder decodes thumbnails once; after that it's
  instant (cached). Face scanning runs in the background and never slows
  the grid — and the faces panel IS the switch: close it (**F** in full
  screen) and scanning stops entirely; open it and it resumes.

## What we want from you

1. Speed: does anything EVER stutter, lag, or beach-ball? That's our #1 bug
   class. Note the folder size, camera, and where the files live (SSD/card).
2. Trust: any file operation that surprised you, any rating that didn't
   stick, anything that made you worry about your photos.
3. Confusion: anywhere you had to guess what to do.

Send screenshots + a sentence. Rough notes are perfect.

## Known limitations (real, on the roadmap)

- Camera support is tuned for Canon CR3 first (full-res embedded previews).
  Other RAW formats work via Apple's decoder — tell us your camera if
  previews feel soft or slow.
- Rejects don't transfer to Lightroom (XMP has no standard for them).
- No backup-destination or checksum-verify pass on ingest yet.
- JPEG-only files don't get XMP sidecars (Lightroom ignores those anyway).
- One window (tabs cover multiple folders; separate windows come later).

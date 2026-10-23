# Previews and name search when the phone browses the laptop

> Status: accepted

A folder of `IMG_4081.jpg` names is hard to pull from. The phone should show
what a file looks like before it takes it, and find a file without opening
every folder (builds on ADR 0026).

## How it works

- `browse_thumb` asks for a picture of one file under a shared folder, `small`
  for a list row or grid tile and `large` for a full-screen preview. The
  answer carries a PNG or JPEG as base64. A file with no picture, or a laptop
  missing the tool, answers `no_thumbnail`, and the phone keeps the icon.
- The relay uses the thumbnail the desktop's file manager already cached
  (`$XDG_CACHE_HOME/thumbnails`), but only when it is not older than the file.
  Otherwise it asks tools already on the laptop: ImageMagick (`magick`, which
  the relay needs anyway) for images, ffmpegthumbnailer for video, and
  pdftoppm for the first page of a PDF.
- Thumbnails the relay makes stay in its memory (24 MB, least recently used
  first). Nothing is written to the desktop's cache. At most two tools run at
  once, each for at most 8 seconds. A failure is remembered, so a scroll back
  does not retry it.
- `browse_search` matches file and folder names under one shared folder, or
  under all of them without `root`. A match carries its `root` and relative
  `path`, so the phone can show where it lives and pull it. Every word of the
  query must appear in the name, ignoring case.
- On the phone the browser fetches pictures four at a time as rows scroll
  into view and skips rows that already scrolled away. It keeps 16 MB of them.
  The folder view can switch between a list and a grid, and tapping a file
  opens a preview with a Download button. The search field filters the open
  folder as you type and offers "Search all shared folders".

## Choosing the shared folders

- The desktop shell's Files pane has a **Shared with the phone** list. A folder
  is added by typing its path (`~` works) and removed with **Stop sharing**.
  A web view has no native folder dialog, so a path field is what the shell
  offers.
- The relay checks that the path is an existing folder, shares its real path
  (a link is followed once, at the time it is added), and refuses `/`. The
  change applies to the phone at once and is written to `relay.json`.
- Only the laptop can change the list. The phone cannot ask for a folder to be
  shared. The control routes are the shell's loopback-only ones.
- Because the list can change while running, the relay now always advertises
  `browse_files`; an empty list answers with no shared folders. The phone
  tells the user to choose folders in the desktop app.
- Root ids are positions in the list. Removing a folder shifts the ids after
  it, so a phone that is mid-browse may see a different folder until it lists
  the roots again.

## Limits

- Browse requests keep the rules of ADR 0026: sealed session only, no hidden
  names, and nothing that resolves outside the shared folder.
- A small picture is at most 160 KB and a large one 3 MB. A large preview
  retries at a smaller size when the first is over the limit, and falls back
  to the small cached picture.
- A search stops at 300 matches, 50,000 entries visited, or 4 seconds, and
  says it was truncated.
- Search is by name only. It does not look inside files.

## Consequences

- The laptop does CPU work and a little disk read per browsed folder. The
  two-tool cap and the timeout keep a large folder from pinning it.
- Pictures show up only for images, videos and PDFs, and only when the laptop
  has the matching tool. The Linux packages recommend `ffmpegthumbnailer` and
  `poppler-utils` without requiring them.
- An older relay does not know these requests, so the phone gets no pictures
  or search matches from it until the relay is updated.

## Considered options

- Pulling the whole file to draw a preview on the phone. It costs the
  bandwidth that browsing is meant to avoid.
- Writing thumbnails into the desktop's cache. It would change files the
  user's file manager owns.
- Searching file contents. It needs an index or a long walk of every file.

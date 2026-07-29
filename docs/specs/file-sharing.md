# File sharing

> Status: implemented; physical-device release gates pending
> Scope: Linux/Wayland laptop ↔ Android phone over the existing paired LAN
> connection

## Product contract

Vidyut transfers explicitly selected regular files between the one paired
laptop and phone. It does not browse remote storage, synchronize folders, or
send across the internet.

Pairing authorizes automatic receipt while **Sync with laptop** and **Receive
files** are on. File sharing remains separate from the latest-only clipboard
pool.

## Entry points

### Laptop → phone

- Send one or more selected files from Dolphin or Nautilus.
- Choose files from the Vidyut tray transfer panel.
- Send immediately after selection; no confirmation screen.

### Phone → laptop

- Share one or more files to Vidyut from Android's share sheet.
- Choose one or more files through Android's system picker inside Vidyut.
- If a share-sheet URI cannot provide durable access and sending cannot start,
  stage an encrypted private copy. Otherwise retain the original reference.

Folders are rejected with guidance to ZIP them. Empty files and every regular
file type are valid.

## Storage

- Default destination: `Downloads/Vidyut` on each receiving device.
- Each device has one independently configurable destination.
- Android custom destinations use a persisted Storage Access Framework tree
  permission.
- If a custom destination becomes unavailable, pause incoming transfers and
  ask the user to repair or change it. Never silently change destination.
- Resolve collisions by preserving both files (`report (1).pdf`).
- Write to an encrypted/inaccessible partial location and atomically finalize
  only after size and hash verification.
- Received files are non-executable regardless of sender metadata.
- Preserve filename, MIME type, size, and last-modified time.

## Queue and batch behavior

- A user action creates one batch containing one or more files.
- Batches are FIFO. Files within a batch transfer sequentially.
- A failed or receiver-rejected file does not stop later files.
- Active and queued work supports pause, resume, cancel, and retry.
- Controls apply to an individual file or an entire batch.
- Cancellation propagates to both devices and deletes incomplete temporary
  data.
- A disabled receiver or master sync switch pauses work rather than cancelling
  it.
- A receiver size-limit change is evaluated when transfer begins; rejected
  files report the exact reason to the sender.

## Offline and retry behavior

- A transfer selected while the peer is offline queues locally.
- Never-started and interrupted transfers remain resumable for seven days.
- Queue and progress survive process restarts and device reboots.
- Resume starts at the last receiver-confirmed chunk.
- A changed or inaccessible source fails clearly and offers a fresh selection.
- Transient failures use exponential backoff and expose **Retry now**.
- A final hash mismatch removes the invalid temporary file and retries once
  from the beginning.
- Hold only the minimum Android wake/network locks needed during active work.
- Metered Wi-Fi is allowed by default, with a receiving option to disallow it.

## Limits and integrity

- Default maximum: 1 GB per file.
- Receiver presets: 100 MB, 500 MB, 1 GB, 5 GB, and Custom.
- A batch has no separate application limit; available destination and staging
  storage are checked before transfer when possible.
- Derive a dedicated file-transfer key from the pairing secret.
- Every chunk is independently authenticated and bound to transfer ID, file ID,
  chunk offset, and declared metadata.
- Verify a final whole-file hash before finalization.
- Sanitize sender filenames, discard path components, reject traversal, and
  safely rename reserved names.
- The relay routes encrypted streams and never keeps completed file contents.

## Transfer surfaces

### Android

A primary **Files** screen shows:

1. active queue;
2. unlimited local metadata history, newest first and grouped by date;
3. filename search and Sent, Received, Failed, and date filters.

Completed rows offer Open, Show in folder, Share onward, Send again, and Remove
from history. Failed rows show the reason and offer Retry and Remove. Received
files can be sent back. If a source no longer exists, **Send again** explains
the problem and offers **Choose replacement**.

History supports per-entry removal, multi-select removal, and confirmed **Clear
all**. None delete transferred files. History does not synchronize between
devices.

### Linux

- A lightweight tray transfer panel shows the same queue and history concepts.
- Left-click opens the panel; right-click exposes quick actions and settings.
- It starts with the existing login service and may be hidden independently of
  the relay.
- If no tray is available, launching Vidyut opens the transfer window.
- File-manager actions continue to work without the tray.

## Notifications

- One updating progress notification per background batch.
- Foreground transfer surfaces replace outgoing progress notifications.
- One completion or failure summary per batch, never one alert per file.
- Completion offers Open or Open folder as appropriate.
- Partial success is **Completed with issues** and offers **Retry failed**.
- Lock-screen notifications hide filenames until unlock.
- Completion sounds/alerts are independently configurable; Android-required
  foreground progress remains visible.

## Settings

Under the existing master **Sync with laptop** switch:

- **Receive files** (default on)
- **Save received files to**
- **Maximum file size** (default 1 GB)
- **Allow metered Wi-Fi** (default on)
- **File transfer alerts**
- **Show tray interface** (laptop only)

Protocol details such as chunk size, encryption, backoff, and concurrency are
implementation policy, not user settings.

## Privacy and pairing lifecycle

- Staged outgoing content and incomplete incoming content are encrypted at rest
  with a local staging key.
- Ordinary app-private history stores filenames; debug logs never do.
- Debug logs use transfer IDs, byte counts, states, and sanitized error
  categories.
- **Forget this laptop** cancels work and deletes queued/partial temporary data.
  It keeps completed files and local transfer history.

## Acceptance criteria

1. Android share sheet/picker and Linux Dolphin/Nautilus/picker send multiple
   files in both directions.
2. A physical Android phone and the actual Linux/Wayland laptop transfer and
   verify a 1 GB file in each direction.
3. Wi-Fi loss, process restart, and device reboot resume from confirmed chunks
   without retransmitting earlier chunks.
4. Pause, resume, cancellation, offline queueing, retry, collision handling,
   low-storage failure, destination revocation, and partial batch success have
   automated seam tests and pass physical-device checks where applicable.
5. Existing clipboard behavior and limits remain unchanged.
6. `bun test`, TypeScript typecheck, Flutter tests, Flutter analyze, and CI are
   green.
7. Supported v1 laptop surface is Linux/Wayland, verified on Hyprland with
   Dolphin and Nautilus integrations.

# KDE Connect file-transfer research

> Researched 2026-07-28 against KDE Connect desktop commit
> `3435f69097534b4c9f077988ec2986e849213be1`, Android commit
> `0150bd323db4da9cd3adb79499c0c6d57ac07be1`, and current Android platform
> documentation.

## What KDE Connect does

KDE Connect separates small JSON control packets from attached binary payloads.
The link implementation supplies `payloadSize` and transfer information rather
than embedding file bytes in JSON. This is the right high-level separation for
Vidyut: clipboard payloads can remain latest-write-wins while files use durable
transfer state.

Sources:

- [KDE Connect protocol overview](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/README.md)
- [Desktop share packet construction](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/share/shareplugin.cpp)

The desktop receiver defaults to the platform Downloads directory, permits a
configured destination, strips path components from sender-controlled
filenames, creates the destination, auto-renames collisions, and preserves
creation and modification timestamps when possible.

Source:

- [Desktop share receiver](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/share/shareplugin.cpp)

Android groups multiple files into one composite job. Files are sent
sequentially, while the packet carries the number of files and total payload
size so the receiver can show aggregate progress. The receiver verifies that
the number of bytes written equals the advertised size and deletes an
incomplete file on mismatch.

Sources:

- [Android composite upload job](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/share/CompositeUploadFileJob.java)
- [Android composite receive job](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/share/CompositeReceiveFileJob.java)

Android uses the Storage Access Framework for a custom destination and takes a
persistable tree permission. Its implementation falls back to Downloads if the
custom directory becomes unwritable. Vidyut deliberately differs here: it will
pause incoming transfers and ask the user to repair the destination, because a
silent fallback makes files difficult to locate.

Source:

- [Android share destination settings](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/share/ShareSettingsFragment.java)

## Android storage constraint

Files delivered to an Android share target commonly carry temporary content-URI
access. The grant may expire when the receiving task ends. A system document
picker can offer persistable access, but arbitrary share providers are not
required to do so. Vidyut therefore must stage only share-sheet sources whose
access cannot be persisted if the transfer cannot start immediately.

Sources:

- [Android secure file sharing](https://developer.android.com/training/secure-file-sharing)
- [Android shared document storage and persisted permissions](https://developer.android.com/training/data-storage/shared/documents-files)

## What Vidyut adopts

- A separate transfer protocol instead of extending the clipboard pool.
- Sequential files within a batch and aggregate progress.
- Downloads-based defaults with configurable destinations.
- Filename sanitization and collision-safe renaming.
- Temporary writes followed by finalization.
- Explicit byte-count and whole-file integrity verification.
- Notifications that summarize a batch rather than alerting once per file.

## Where Vidyut intentionally differs

- One existing relay port rather than an extra temporary payload port.
- WebSocket control plus receiver-pulled HTTP byte streams.
- End-to-end encrypted chunks using a file-specific key derived from pairing.
- Durable FIFO state, manual pause, seven-day offline queueing, and resume after
  Wi-Fi loss, process restart, or device reboot.
- A final whole-file hash in addition to per-chunk authentication.
- Unlimited local metadata history without copying completed file contents.
- A custom destination failure pauses transfers instead of silently changing
  where files are stored.


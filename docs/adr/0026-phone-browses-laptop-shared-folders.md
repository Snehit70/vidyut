# The phone browses the laptop's shared folders

> Status: accepted

Sending from the laptop means walking over to it. When the file is already
there and the phone is in hand, the phone should be able to look and take it,
a single file or a whole folder.

## How it works

- The laptop shares a list of folders, `sharedFolders` in `relay.json`. The
  default is Desktop, Documents, Downloads, Music, Pictures and Videos under
  the home folder. An empty list turns browsing off, and the relay then stops
  advertising `browse_files` in its hello.
- The phone asks over the paired WebSocket: `browse_list` with no root returns
  the shared folders, with a root and path it returns that folder's entries,
  and `browse_pull` asks for files and folders under one root. Every answer is
  a `browse_result` matched by `requestId`. Refusals come back as a failed
  answer, never as an `error`, which would end the session.
- Browse messages travel only on a sealed session (ADR 0023): listings carry
  filenames. An unsealed session gets `seal_required`.
- A pull queues an ordinary laptop → phone transfer, so it is encrypted,
  resumable, and received by the background service like any laptop send.
  The laptop answers once the files are listed and size-checked, and hashes
  and queues them after the answer, since that can take minutes.
- A pulled folder keeps its shape. Each file offer carries `folder`, the
  relative path from the pulled folder's own name down, and the phone writes
  the file to `Downloads/Vidyut/<folder>/` or the matching folders under a
  chosen receive folder. A pull is split into offers of 100 files.

## Limits

- Paths from the phone are relative to a shared folder. A segment that is
  empty, `.`, `..` or hidden is refused, and the resolved path must stay inside
  the shared folder after symlinks resolve.
- Hidden entries and symlinks are never listed or pulled, so sharing the home
  folder does not hand out `~/.ssh` or a link out of the share.
- A listing stops at 2000 entries and says so. A pull is at most 1000 files,
  and every file must fit the phone's receive limit, or nothing is queued.

## Consequences

- Browsing is read-only. The phone cannot delete, rename or write on the
  laptop.
- Shared folders are set in `relay.json` only, and the relay reads them at
  start. There is no picker in the desktop shell yet.
- If **Receive files** is off on the phone, a pull queues and then waits,
  like any laptop send.
- An older phone never sends browse messages; an older laptop never
  advertises `browse_files`, so the phone says to update instead of asking.

## Considered options

- An HTTP file server on the transfer port. It would need its own auth and
  encryption for listings, where the sealed WebSocket already has both.
- Mirroring folders onto the phone. Costs storage and battery for files the
  user may never want.

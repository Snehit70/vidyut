# The laptop shows the phone screen in a window

> Status: accepted

People wanted to see the phone on the laptop: to follow a video call, show
an app, or read a long screen without picking the phone up. The relay
already holds a sealed session to the phone, so it can hand out a stream key
and play the stream without a new pairing or a new port.

The design follows the mirror in bjarneo/flux: the screen goes through a
hardware H.264 encoder and a stock player shows it with its buffering off.
This mirror is view-only, with no touch or keyboard input and no audio.

## What changed

- **Ticket.** In **Settings → Connection**, **Mirror screen** asks Android
  for screen capture, then sends a sealed `screen_start {width, height}` on a
  short session of its own. The relay answers with sealed
  `screen_ready {streamId, key}`, where `streamId` is 18 random bytes in
  base64url and `key` is a fresh 32-byte AES key. A relay without a player
  answers `screen_failed {code: "no_player"}`. An unsealed session gets
  `seal_required` and never sees a key. The relay advertises
  `screen_mirror` in `hello`, and the phone asks only then.
- **Stream.** Within 15 seconds the phone opens a WebSocket on
  `/screen/v1/<streamId>`, on the relay's own port, so no new firewall rule
  is needed. A ticket admits one socket. Each binary message is one record:
  AES-256-GCM ciphertext with the 16-byte tag at the end, under a nonce of
  four zero bytes and a 64-bit big-endian record counter from 0. A dropped,
  replayed or changed record fails to open and the relay ends the stream.
  A record is at most 4 MiB.
- **Phone.** The `screen_mirror` plugin runs a `mediaProjection` foreground
  service with a Stop action in its notification. MediaProjection draws into
  a `video/avc` encoder surface at 30 fps with a keyframe every 2 seconds.
  The long side is capped at 1920 pixels and shrunk until the encoder takes
  it. The codec config rides on every keyframe. Frames wait in a six-frame
  queue. When it is full, the phone drops frames up to the next keyframe and
  asks the encoder for one, so the laptop never falls behind the screen.
- **Laptop.** The relay pipes the opened stream into `mpv` with the
  low-latency profile and no cache, or `ffplay` when mpv is missing. The
  window's Wayland app id is `vidyut-screen`, for compositor rules. The
  `.deb` and `.rpm` recommend `mpv`.
- **Ending.** Closing the window closes the phone's socket and stops the
  capture. Stop on the phone, tapping **Mirror screen** again, or revoking
  capture closes the socket and the relay closes the window. A new start
  replaces a mirror that runs. There is one mirror at a time.

## Why a WebSocket and not a chunked POST

The first sketch, in issue #70, streamed one long POST. Bun buffers request
bodies up to a server-wide cap, and raising that cap would also loosen the
transfer endpoints. A WebSocket on the same port keeps per-message limits,
gives a close signal in both directions, and needs no new listener.

## Consequences

- The stream is as private as the rest of the session: the key only travels
  sealed, and only for the stream it was made for.
- The virtual display keeps the size it started with. Turning the phone on
  its side shows the landscape picture letterboxed inside the portrait frame.
  Restarting the mirror picks up the new orientation.
- The player runs as the relay's user. A relay started as a systemd user
  service needs the graphical session's `WAYLAND_DISPLAY` or `DISPLAY`, which
  the desktop session normally imports.
- Android shows its own capture prompt every time; a grant is good for one
  start.
- The Kotlin capture service is compile-checked in CI, not exercised by
  tests.

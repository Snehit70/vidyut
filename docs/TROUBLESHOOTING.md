# Troubleshooting

Field-verified fixes from real debugging sessions on the owner's setup (Fedora +
Hyprland laptop, Xiaomi HyperOS phone). Symptom → cause → fix. Add new entries
as they are diagnosed; only record what was actually reproduced and fixed.

## Contents

- [Phone: tapping "Send clipboard" on the notification does nothing](#phone-tapping-send-clipboard-on-the-notification-does-nothing)
- [Phone: send screen says "Clipboard is empty" when launched from the notification](#phone-send-screen-says-clipboard-is-empty-when-launched-from-the-notification)
- [Phone: connection silently dies after ~30 minutes idle and never recovers](#phone-connection-silently-dies-after-30-minutes-idle-and-never-recovers)
- [Phone: notification button semantics (for future debugging)](#phone-notification-button-semantics-for-future-debugging)
- [Laptop: relay changes don't show up after `systemctl --user restart`](#laptop-relay-changes-dont-show-up-after-systemctl---user-restart)
- [Held screenshot lost after the relay restarts (`payload_stale_dropped`)](#held-screenshot-lost-after-the-relay-restarts-payload_stale_dropped)
- [Laptop: `clipboard_write` logs seconds after the payload arrived, acks stall](#laptop-clipboard_write-logs-seconds-after-the-payload-arrived-acks-stall)
- [Laptop: image is on the clipboard but Ctrl+V pastes nothing](#laptop-image-is-on-the-clipboard-but-ctrlv-pastes-nothing)
- [Laptop → phone never publishes on KDE/KWin](#laptop--phone-never-publishes-on-kdekwin)
- [Laptop: did the payload even arrive? The relay logs nothing](#laptop-did-the-payload-even-arrive-the-relay-logs-nothing)
- [Dashboard/relay "bytes" is larger than the text you copied (+17 for text)](#dashboardrelay-bytes-is-larger-than-the-text-you-copied-17-for-text)
- [Phone: stuck on "Searching" after a laptop reboot — service isolate wedged](#phone-stuck-on-searching-after-a-laptop-reboot--service-isolate-wedged)
- [Laptop: duplex clipboard sync dies until `vidyut-relay` is restarted](#laptop-duplex-clipboard-sync-dies-until-vidyut-relay-is-restarted)

## Phone: tapping "Send clipboard" on the notification does nothing

**Symptom:** The notification button gives no visible reaction. Opening the app
manually afterwards fires the queued send immediately — so the tap clearly
*reached* the app.

**Cause:** Android 12+ blocks "notification trampolines": a service handling a
notification tap may not launch an activity. MIUI/HyperOS stacks its own
background-start gate on top. Verified in logcat at the moment of the tap:

```
NotificationService: Indirect notification activity start (trampoline)
                     from dev.snehit.vidyut.vidyut blocked
ActivityTaskManager: Abort background activity starts from 10388
```

**Fix (verified 2026-07-10):** the app must hold the **overlay permission**
(`SYSTEM_ALERT_WINDOW`) — it is on Android's exemption list for background
activity starts. Two parts:

1. The manifest must declare `android.permission.SYSTEM_ALERT_WINDOW`,
   otherwise the app never appears in the overlay-permission settings list and
   `adb shell appops set ... SYSTEM_ALERT_WINDOW allow` silently stays
   `default` on MIUI.
2. Grant it: Settings → Apps → Vidyut → "Display over other apps" → Allow
   (open the page directly with `adb shell am start -a
   android.settings.action.MANAGE_OVERLAY_PERMISSION -d
   package:dev.snehit.vidyut.vidyut`).

**Dead end, recorded to save the next hour:** MIUI's Other-permissions toggle
"Open new windows while running in the background" did **not** lift the block —
logcat showed the identical trampoline abort after enabling it. Only the
overlay grant flipped `allowBackgroundActivityStart`. Belongs in the
onboarding checklist (WP6).

**Diagnosis recipe:** `adb logcat -c`, tap the button, then
`adb logcat -d | grep -iE 'trampoline|Background activity'`.

## Phone: send screen says "Clipboard is empty" when launched from the notification

**Symptom:** Launching the send flow from the notification button reports an
empty clipboard even though Gboard's clipboard shows the copied text. Opening
the app first and navigating manually works.

**Cause:** Android 10+ only allows clipboard reads while the app's window has
*input focus*. On a cold launch from a notification the first frames render
before focus lands, so an immediate read comes back empty. (KDE Connect reads
in `onWindowFocusChanged(true)` for the same reason.)

**Fix:** Fixed in code — `SendClipboardScreen` retries the read (250ms × 10)
before concluding the clipboard is empty. If it regresses, check that the
retry loop in `app/lib/src/foreground/send_clipboard_screen.dart` still runs.

## Phone: connection silently dies after ~30 minutes idle and never recovers

**Symptom:** Relay socket to the phone goes dead ~28 minutes after the screen
turns off; the app's reconnect/backoff never fires; connection returns only
when the app is manually opened.

**Cause:** MIUI **freezes the entire app process** when idle — not just the
network. A frozen process can't run reconnect timers, so client-side recovery
logic is powerless. Measured 2026-07-10: kill at 28 idle minutes *despite*
Battery saver already set to "No restrictions".

**Fix:** **Lock the app in recents** (open recents, pull the Vidyut card
down until the padlock shows). This was the decisive lever: same socket
survived 67+ minutes with zero drops afterwards. Supporting toggles: Battery
saver "No restrictions", app hibernation ("Pause app activity if unused") off.
Full data: wayfinder ticket #26.

## Phone: notification button semantics (for future debugging)

The flutter_foreground_task plugin wires the notification **body** tap as a
direct activity PendingIntent (always works), but **buttons** as broadcasts to
the service (`ForegroundService.kt:580` in the plugin) — anything a button does
that needs UI must survive the background-activity-start rules above. If a
button flow breaks again on a new Android/MIUI version, suspect this first;
the quick-settings-tile approach (allowed to launch activities, what KDE
Connect uses) is the documented fallback.

## Laptop: relay changes don't show up after `systemctl --user restart`

**Symptom:** Rebuilt the relay (`bun run build:relay`), restarted the service,
but new behavior/log events don't appear.

**Cause:** The systemd unit runs `%h/.local/bin/vidyut-relay`, not the repo's
`dist/vidyut-relay`. A rebuild only updates `dist/`; restarting relaunches
the stale installed copy.

**Fix (verified 2026-07-10):** `install -m 755 dist/vidyut-relay
~/.local/bin/vidyut-relay` (or the full `bun run install:relay`), *then*
restart the service.

**Mirror trap (verified 2026-07-11):** `bun run install:relay` alone is not
enough either — the script ends with `systemctl --user enable --now`, which is
a no-op when the service is already running, so the old process keeps serving
the stale binary (check: the PID in `journalctl` output doesn't change). Always
follow an install with an explicit `systemctl --user restart vidyut-relay`.
The phone drops with wsCode 1006 and auto-reconnects within the backoff window.

## Held screenshot lost after the relay restarts (`payload_stale_dropped`)

**Symptom:** Phone holds a screenshot while the relay is down (`screenshot_held`
logged on the phone). After the relay restarts and the phone reconnects, the
image never reaches the laptop clipboard; the relay logs `payload_stale_dropped`
for it with `frameTs < currentTs`, and a `payload_broadcast{replay:true}`
carrying old content fired just before.

**Cause:** `wl-paste --watch` fires once immediately for the selection that
already exists at relay startup. The relay treated that startup fire as a real
change and re-published the current laptop clipboard with a fresh `now()`
timestamp. That phantom payload is newer than the held frame (stamped at
capture time during the outage), so the pool's `ts` stale-check drops the held
frame. Only bites when the relay itself restarts (laptop sleep/wake, crash,
reboot) — the exact case offline-hold covers.

**Fix (verified 2026-07-11):** the Wayland adapter (`src/relay/clipboard.ts`)
swallows the first `wl-paste --watch` fire; every later one is a real change.
Confirmed on-device: restart no longer re-publishes the clipboard, and a
screenshot held across a full relay stop/start now republishes and lands.

## Laptop: `clipboard_write` logs seconds after the payload arrived, acks stall

**Symptom:** A phone payload reaches the relay instantly (`payload_published`
with a small `relayLagMs`), but `clipboard_write` logs 10–20s later with a huge
`e2eMs`, and the phone's `screenshot_acked` shows the same `ackMs`. The
clipboard content itself is pasteable immediately.

**Cause:** `wl-copy` forks a daemon to serve the selection, and the daemon
inherits the stdout/stderr pipes. The relay's process runner waited for pipe
EOF, which only happens when the daemon **loses the selection** — so every
write resolved on the *next* clipboard change, stalling the ack and poisoning
the `e2eMs` metric. Reproduced standalone: the same spawn pattern hung 165s
and resolved the instant another `wl-copy` ran.

**Fix (verified 2026-07-11):** `detachOutput` in `src/relay/clipboard.ts` —
for `wl-copy` writes, await only the direct child's exit and never the pipes
(a failing wl-copy exits before forking, so stderr is still readable on
nonzero exit). Write latency went 165,543ms → 17ms on a 186KB image.

## Laptop: image is on the clipboard but Ctrl+V pastes nothing

**Symptom:** `wl-paste --list-types` shows the phone image arrived (relay
logged `clipboard_write`), local screenshots paste fine, but Ctrl+V of the
phone image does nothing in browsers/Electron apps.

**Cause:** Format, not delivery. MIUI screenshots arrive as `image/jpeg` (the
share-sheet path can even arrive as a non-concrete `image/*`), and most Linux
apps only accept `image/png` from the clipboard — they see a jpeg-only offer
and silently decline. Local screenshot tools always offer PNG, which is why
those paste.

**Fix (verified 2026-07-11):** the relay re-encodes any non-PNG image through
ImageMagick (`magick - png:-`) before the clipboard write and offers
`image/png`; `magick` sniffing the real format from the bytes also repairs the
`image/*` case. Missing/failing `magick` falls back to writing the raw bytes
(the old behavior). Conversion adds ~1s for a full phone screenshot — budget
this against the 2s screen-on bar. Requires `ImageMagick` installed on the
laptop.

## Laptop → phone never publishes on KDE/KWin

**Symptom:** the phone is connected and phone → laptop payloads work, but
laptop copies never produce `clipboard_published`. `/health` reports
`status:"degraded"` with a failed `wl-paste --watch` clipboard watcher.

**Cause (verified 2026-07-23 on Fedora 43, KWin 6.6.5):** `wl-clipboard` 2.2.1
only watches through the wlroots data-control protocol. KWin exposes the
standardized `ext-data-control-v1` protocol instead, so the watcher exits
immediately. `wl-clipboard` 2.3 added support for KWin's protocol.

**Fix:** check `wl-paste --version` and manually install
[wl-clipboard 2.3+](https://github.com/bugaevc/wl-clipboard/releases/tag/v2.3.0)
when the distribution package is older, then restart `vidyut-relay`. Vidyut
does not replace system packages itself. The relay now logs
`clipboard_watch_failed` and exposes the exact failure under `/health` instead
of silently claiming clipboard sync is enabled.

## Laptop: did the payload even arrive? The relay logs nothing

Use these diagnosis tools:

- One-curl overview: `curl http://localhost:17321/health` — uptime, authenticated
  devices (with last-seen age), and current pool payload identity/age.
- Live socket check: `ss -tn state established '( sport = :17321 )'`
- Reconnect cadence monitor: loop `ss` output and log changes (see ticket #26
  resolution for the script).
- Laptop clipboard content: `wl-paste --list-types` and `wl-paste | head -c 200`.

## Dashboard/relay "bytes" is larger than the text you copied (+17 for text)

**Symptom:** Copy a 62-byte string on the laptop; the phone's Last-activity card
and the relay's `clipboard_published`/`clipboard_write` logs report **79 B**.
The offset is a constant **+17** on every text payload (30→47, 50→67, 62→79),
which first looks like a stale-clipboard read race but is fully deterministic.

**Cause:** Two stacked, benign offsets — nothing is corrupted in transit:

- **+16 — encryption tag.** `encodedPayloadBytes()` (`src/shared/wire.ts`)
  measures the *ciphertext*: `Buffer.from(frame.payload,"base64").byteLength`.
  Payloads are AES-GCM encrypted (`src/shared/crypto.ts`), and WebCrypto appends
  a 16-byte auth tag to the ciphertext. So the metric is wire size, not
  plaintext size — correct by definition, just not the number the user typed.
- **+1 — trailing newline.** The relay reads the clipboard with
  `wl-paste --type <mime>` and **no `-n`** (`src/relay/clipboard.ts:54`), so
  `wl-paste` appends a `\n`. That newline rides along to the phone: laptop→phone
  text gains a trailing newline it didn't have on the source.

**Verified 2026-07-11** via the seamless-sync path on-device: three copies at
30/50/62 B each published exactly +17; the laptop clipboard read back the exact
original bytes, and a round-tripped screenshot arrived byte-clean (854ms e2e),
so the payload body is intact.

**Fix (verified 2026-07-11):** the +16 is expected wire overhead and stays.
The +1 trailing newline was a real fidelity quirk — a copied password/token
arrived as `token\n` on the phone — fixed by adding `-n` to the `wl-paste
--type` read in `src/relay/clipboard.ts`, which emits the exact clipboard bytes
(`-n` is auto-enabled for binary content, so images are unaffected). Confirmed
empirically that `wl-paste -n` returns the stored bytes verbatim even when the
content legitimately ends in a newline. Requires a relay rebuild + restart to
take effect. Not a regression from the home/settings redesign — this was
long-standing relay behavior.

## Phone: stuck on "Searching" after a laptop reboot — service isolate wedged

**Symptom:** Laptop reboots; relay comes back healthy (auto-started by systemd,
port listening, mDNS answering). Phone app opened afterwards shows "Searching"
forever. Every relay `payload_broadcast` logs `recipients:0` and `ss -tn | grep
17321` shows zero connections on both ends — the phone is not even *attempting*
to connect. Verified 2026-07-12: app process alive, foreground service alive
(`dumpsys activity services` shows `isForeground=true`), phone→laptop TCP to
17321 connects fine from a shell (`nc` exit 0), pairing host/port correct on
the dashboard — yet the app's Debug log shows **"No debug events yet"**: the
service isolate emitted nothing (no status, no logs) even after the UI sent it
the `sync` command on open.

**Cause:** The service isolate's reconnect machinery is wedged in a stuck
`await`. The exact await wasn't pinned from outside, but the shape is: the
relay socket died while the process was frozen/mid-reboot, and every recovery
path (`handleTaskData` sync, screen-on trigger, reconnect timer) funnels
through `ServiceRelayController._sync()` → `await _teardown()` →
`RelayConnection.close()`, none of which carry a timeout — one poisoned future
wedges every subsequent recovery attempt forever. The screen-on fast-path also
early-returns when `_lastStatus == connected`, so a stale "connected" belief
disables that rescue too.

**Fix (verified 2026-07-12):** Kill and relaunch the app — the wedged state is
process-local. Via adb: `adb shell am force-stop
dev.snehit.vidyut.vidyut && adb shell am start -n
dev.snehit.vidyut.vidyut/.MainActivity`; on the phone: App info → Force
stop, then reopen. Reconnection after the fresh start was immediate
(`device_connected` → `auth_ok` in 132ms, pool replay `recipients:1`, live
laptop→phone text landed). The Settings "Sync with laptop" off/on toggle is
NOT a verified recovery — `stopService` may await the same poisoned teardown.
Durable fix ideas (not yet implemented): timeout-guard `_teardown()`/`close()`,
add a service-isolate watchdog that forces a fresh `_sync` when disconnected
too long, and make the screen-on trigger verify the socket instead of trusting
`_lastStatus`.

## Laptop: duplex clipboard sync dies until `vidyut-relay` is restarted

**Symptom:** Phone stays "connected", but copies stop moving in one or both
directions. Restarting `systemctl --user restart vidyut-relay` (not the phone
app) brings sync back.

**Cause:** `wl-paste` / `wl-copy` / `magick` can block forever on a stuck
Wayland selection owner. Three code bugs turned that into a dead relay:

1. The clipboard watch loop `await`ed every change with no `try/catch`, so one
   thrown `wl-paste` killed laptop→phone watching until process restart.
2. Those tools were spawned with no timeout, so a hung `wl-paste --list-types`
   held the watch loop (and, on Hyprland, the data-control device).
3. Phone publish acked only after the laptop clipboard write finished, so a
   hung `wl-copy`/`magick` wedged that WebSocket's message handler.

**Fix:** 5s kill-timeout on clipboard processes, watch loop survives a thrown
change, read/write are serialized, and the phone's ack no longer waits on the
Wayland write. Rebuild, install, and restart the relay:

```
bun run build:relay
install -m 755 dist/vidyut-relay ~/.local/bin/vidyut-relay
systemctl --user restart vidyut-relay
```

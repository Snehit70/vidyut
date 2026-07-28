# Manual Two-Direction E2E Script

This is the acceptance script for Vidyut v1: laptop ↔ phone clipboard sync verified in both directions on real hardware. Run every step in order; the run is **green** only if every ✅ checkpoint passes.

Hardware: the Linux/Wayland laptop running the relay and the Android phone, on the same WiFi.

## 0. Preconditions

On the laptop:

```bash
systemctl --user status vidyut-relay        # active (running)
journalctl --user -u vidyut-relay -b --no-pager | tail -40   # QR + manual pairing line
```

If the relay is not installed yet, run `bun run install:relay` from the repo root (see `docs/INSTALL.md`).

On the phone:

- Install the debug APK: `adb install -r app/build/app/outputs/flutter-apk/app-debug.apk` (build with `cd app && flutter build apk --debug`).
- MIUI: Settings → Battery → Vidyut → **No restrictions**, so the foreground service survives backgrounding.
- Phone and laptop on the same WiFi network.

## 1. Pairing

1. Open Vidyut on the phone.
2. The pairing screen should list the relay discovered over mDNS (`_vidyut._tcp`). Tap it — host/port fill in; enter only the secret from the journal line.
   - ✅ Relay appears in the discovery list without typing host/port.
   - Fallback: scan the QR from the journal, or type the full `host=… port=… secret=…` line manually.
3. Pair.
   - ✅ App shows **connected** status.
   - ✅ A persistent foreground notification appears showing connection status.
   - ✅ Relay journal logs the device authenticating.

## 2. Laptop → phone: text

1. On the laptop, copy a distinctive string:

   ```bash
   printf 'e2e-text-%s' "$(date +%s)" | wl-copy
   ```

2. On the phone (app backgrounded, screen on):
   - ✅ A notification arrives for the incoming text payload.
3. Tap the notification.
   - ✅ App foregrounds and copies the text.
4. Paste into any text field (e.g. a notes app).
   - ✅ Pasted text matches the string exactly.

## 3. Laptop → phone: image (screenshot)

1. Take a screenshot on the laptop and put it on the clipboard (Hyprland example):

   ```bash
   grim -g "$(slurp)" - | wl-copy --type image/png
   ```

2. On the phone:
   - ✅ Notification arrives for the incoming image payload.
3. Tap the notification.
   - ✅ App foregrounds and copies the image.
4. Paste into an image-accepting field (e.g. a messaging app compose box).
   - ✅ The screenshot pastes intact.

## 4. Phone → laptop: text

1. In any phone app, select text → Share → **Vidyut**.
2. On the laptop:

   ```bash
   wl-paste
   ```

   - ✅ Output matches the shared text exactly.

## 5. Phone → laptop: image

1. In the phone gallery, share a photo → **Vidyut**.
2. On the laptop:

   ```bash
   wl-paste --list-types          # should include image/png
   wl-paste --type image/png > /tmp/e2e-recv.png
   xdg-open /tmp/e2e-recv.png
   ```

   - ✅ The received image opens and matches the shared photo.

## 6. Reconnect resilience

1. Toggle WiFi **off** on the phone, wait ~15 seconds, toggle it back **on**.
   - ✅ Foreground notification shows disconnected, then reconnects on its own (backoff starts at 2s).
   - ✅ No duplicate notification for the payload already in the pool after re-auth.
2. Repeat step 2 (laptop → phone text) once after reconnecting.
   - ✅ Sync still works.

## 7. Observability spot-check

- Open the in-app debug log (bug icon in the app bar).
  - ✅ Entries show the connection, auth, payload (type/size/origin), and send events from this run.
- `journalctl --user -u vidyut-relay -f` during a sync.
  - ✅ Relay emits structured, timestamped, leveled log lines.

## Recording a run

Append a dated line to the table below after each full run.

| Date | APK commit | Result | Notes |
|------|-----------|--------|-------|

---

# Seamless Sync acceptance (§8–§12)

Acceptance script for the Seamless Sync effort (`docs/specs/seamless-sync-plan.md`).
**Run only once the plan's work packages are implemented** — these steps exercise
features that do not exist in v1. Preconditions on top of §0: onboarding completed with
full photos access and battery exemption, MIUI toggles applied (No restrictions,
lock-in-recents, hibernation off), auto-push toggle on.

Log taps used throughout:

```bash
relay-log() { journalctl --user -u vidyut-relay -o cat "$@"; }   # one JSON object per line
relay-log -f | jq -c 'select(.message=="clipboard_write") | {nonce, e2eMs}'
```

Phone-side numbers come from the in-app debug log (bug icon in the app bar).

## 8. Zero-tap receive (laptop → phone)

1. App backgrounded, screen off. On the laptop: `printf 'e2e-zerotap-%s' "$(date +%s)" | wl-copy`.
2. Wake the phone and paste into any text field — no taps in between.
   - ✅ Pasted text matches exactly (clipboard was written silently by the service).
   - ✅ A **quiet** receipt appeared ("Copied from laptop") — no heads-up, no sound.
   - ✅ Debug log shows the write outcome `confirmed` (not `blocked` / wiring-bug).
3. Repeat with an image (`grim -g "$(slurp)" - | wl-copy --type image/png`) → paste intact.
4. Settings → receive notifications **off**, send another text.
   - ✅ Clipboard still written; no success receipt shown.
5. If the device reports `blocked` (MIUI): ✅ the one-time MIUI hint appeared exactly
   once, and the receipt's tap-to-copy still delivers the payload.

## 9. Screenshot auto-push, screen-on ≤2s (phone → laptop)

1. Screen on, connected, app backgrounded. Take ≥10 screenshots, a few seconds apart.
2. After each: `wl-paste --list-types` on the laptop includes `image/png` and the image matches.
   - ✅ Zero taps end to end.
3. Latency, per screenshot: phone debug log `captureToDetectMs` + relay `e2eMs`
   (`relay-log | jq -r 'select(.message=="clipboard_write") | .e2eMs'`).
   - ✅ Median of `captureToDetectMs + e2eMs` over the ≥10 samples ≤ **2000ms**.
4. Burst: five rapid screenshots.
   - ✅ Laptop clipboard ends with the newest; `screenshot_skipped{reason: superseded}` logged; no crash.
5. Take a camera photo and save an image from a browser.
   - ✅ Neither is pushed (filter drops non-screenshots).

## 10. Offline hold and doze delivery

1. Stop the relay (`systemctl --user stop vidyut-relay`). Take a screenshot.
   - ✅ Phone logs `screenshot_held`.
2. Start the relay. After the phone reconnects:
   - ✅ Phone logs `screenshot_republished{heldForMs}`; relay logs the replay signature
     `device_connected → auth_ok → payload_broadcast{replay: true}`; image lands on the laptop clipboard.
   - ✅ Exactly one `screenshot_acked` for the frame (no duplicate delivery).
3. Doze variant: screen off ≥30 min (no charger), then send a text from the laptop
   (`payload_broadcast.recipients: 0` in the relay log). Wake the phone.
   - ✅ Payload arrives by the reconnect (delivery gap = `auth_ok.ts − payload_published.ts` in the relay log).

## 11. Screen-on reconnect ≤2s

1. Force a dead socket (e.g. relay stopped ≥5 min so backoff is at its 32s cap, then start the relay), screen off.
2. Wake the phone (screen on) and immediately watch the relay log.
   - ✅ `auth_ok{connId}` within **2s** of the screen-on debug-log line on the phone.

## 12. Idle survival (keepalive)

1. Toggles applied (§ preconditions), service running, screen off ≥60 min. Monitor:

   ```bash
   relay-log -f | jq -c 'select(.message=="socket_reaped" or .message=="device_disconnected" or .message=="device_connected")'
   ```

   - ✅ **Zero** `socket_reaped` events over the window.
   - ✅ Any `device_disconnected` carries an attributable `wsCode`/`wsReason` (no silent deaths).
2. After the window, send one payload each way.
   - ✅ Both deliver without manual intervention.

## Recording a seamless-sync run

| Date | APK commit | §8 | §9 median ms | §10 | §11 | §12 | Notes |
|------|-----------|----|--------------|-----|-----|-----|-------|
| 2026-07-11 | 72885c5 (relay 45fda60) | ✅ text | ✅ ~935 | ✅ hold | ✅ daily use | ✅ daily use | adb-driven core pass followed by many days of stable owner use, accepted as the screen-off, reconnect, and long-idle soak. §8: zero-tap text write `confirmed` (D3), screen off, quiet receipt. §9: 10-sample median e2eMs 855ms + sinceDetectMs ~80ms ≈ 935ms (≪2000); burst 6→1 supersede on-device; 7-event instrumentation all present. §10.1–2: `screenshot_held` offline, then clean republish on reconnect (device_connected→auth_ok→payload_published(image)→clipboard_write, no stale drop). Also fixed this session: wl-copy ack stall (17s→17ms) and jpeg→png paste refusal. |

# Vidyut Implementation Status

This file is a live gap map against `docs/PRD.md`. It is not a replacement for the PRD.

## File Sharing Implemented

- The accepted two-way file-sharing product and behavior contract lives in
  `docs/specs/file-sharing.md`; KDE Connect and Android storage research lives
  in `docs/research/kde-connect-file-transfer.md`.
- File sharing is a separate durable transfer module rather than a new
  clipboard payload type (ADR 0007).
- TypeScript and Dart share validated transfer-offer metadata: stable
  transfer/batch/file identities, direction, safe basenames, MIME, size,
  modified time, and whole-file SHA-256.
- The authenticated relay routes typed transfer control between the phone and a
  local laptop transfer adapter without logging filenames.
- TypeScript and Dart implement a dedicated file-transfer key derivation and
  independently authenticated AES-GCM chunks bound to transfer ID, file ID,
  offset, byte count, and nonce.
- The laptop has a durable JSON-backed FIFO queue with atomic persistence,
  crash recovery from receiver-confirmed progress, seven-day expiry,
  pause/resume/cancel/retry, partial-batch continuation, and unlimited retained
  metadata history.
- Pairing-secret-authenticated transfer HTTP requests share the relay's existing
  port; method, path, query, and a bounded timestamp are signed.
- The laptop→phone data-plane adapter serves independently encrypted 256 KiB
  source ranges only from the last receiver-confirmed offset, supports empty
  files, and rejects changed, missing, short, or inaccessible sources.
- Phone→laptop uploads use the same authenticated encrypted chunk plane,
  hidden partial files, final SHA-256 verification, collision-safe atomic
  finalization, and preserved modified times.
- `vidyut-relay --send` queues selected laptop files through the running relay;
  `--transfers` prints durable queue/history state. The installer adds a
  picker, Yad tray, transfer-history panel, Dolphin service menu, and Nautilus
  script.
- Android accepts generic single/multiple share intents and system-picker
  selections, provides searchable/filterable Files history with retry/remove/
  clear actions, and receives in the foreground-service engine.
- Android publishes verified receives to `Downloads/Vidyut` through MediaStore
  or a persisted custom Storage Access Framework folder, preserving both files
  on collisions. Private staging is removed only after publishing succeeds.
- Receive, maximum-size, metered-network, destination, and batch-alert settings
  are enforced. Batch completion/failure uses one notification.
- Automated TypeScript/Dart seams cover wire validation, auth, chunk crypto,
  relay routing, queue persistence/recovery, both data-plane directions, and
  Android sender/receiver/history.
- Remaining release gate: physical-device/laptop fault-injection and 1 GB
  transfers in both directions, as required by `docs/specs/file-sharing.md`.

## Implemented And Verified

- Relay WebSocket authentication rejects wrong pairing secrets.
- Relay broadcasts encrypted payload frames to paired devices.
- Late joiners receive the current pool payload.
- Latest timestamp wins; older payloads do not replace newer payloads.
- Oversized encrypted payloads fail with a clear protocol error.
- AES-256-GCM encrypt/decrypt works for payload frames; wrong key and tampered metadata fail.
- Wayland clipboard read/write/watch is behind a fakeable process boundary.
- Local clipboard changes publish encrypted payloads into the pool.
- Incoming remote payloads decrypt and write into the laptop clipboard.
- Relay config persists pairing secret, port, max payload size, device ID, and log level.
- Relay CLI prints QR plus manual pairing details.
- Relay advertises `_vidyut._tcp` through mDNS.
- Relay compiles into `dist/vidyut-relay`.
- Flutter Android app exists and builds a debug APK.
- Android QR/manual pairing UI stores relay host, port, and pairing secret in secure storage.
- Android WebSocket client authenticates with the same pairing proof as the relay.
- Android app is registered as a system share target for `text/plain` and `image/*`.
- Android share intake maps incoming text/image shares and publishes encrypted payloads after relay auth.
- Android app has a settings screen with persisted notification preferences.
- Incoming payload notifications can be disabled from the app settings.
- Android foreground service runs while paired when the background-sync setting is enabled.
- The foreground notification exposes a `Send clipboard` action that launches a focused clipboard-send flow.
- The foreground service owns the relay receive connection (`ServiceRelayController` in the task isolate): laptop payloads decrypt and land while the app is backgrounded, the persistent notification reflects connection status, and the UI observes status/receive events over the task data channel instead of holding a socket.
- Cross-language crypto fixtures: `tests/fixtures/crypto-fixtures.json` is generated by `tests/fixtures/generate.ts` and verified byte-for-byte by both `tests/crypto-fixtures.test.ts` and `app/test/crypto_fixtures_test.dart`, covering payload frames (ASCII, binary, unicode metadata, empty plaintext), tamper rejection, and pairing proofs.
- Relay installs as a `systemd --user` service: `bun run install:relay` builds the binary, installs the unit from `packaging/systemd/`, and enables it; install/pairing docs in `docs/INSTALL.md`.
- CI (`.github/workflows/ci.yml`) runs relay typecheck/tests and Flutter analyze/tests on push to main and PRs. Releases publish the compiled relay binary and a signed ARM64 release APK, with checksum, package/version/ABI/certificate, and size verification before upload.
- Incoming text payloads are stored (latest-write-wins, secure storage) and their notification carries a copy payload: tapping it foregrounds the app, which writes the stored text to the Android clipboard (`ReceiveNotificationTapHandler`), covering warm taps and cold launches. The service-isolate clipboard write remains as a best-effort fast path since Android 10+/MIUI can reject background writes.
- Incoming image payloads are persisted to app-private storage (latest-write-wins, `ReceivedImageRepository`) and their notification carries a copy payload: tapping it foregrounds the app, which writes the image to the Android clipboard through the `vidyut/clipboard` platform channel (`ClipData` + FileProvider content URI in `MainActivity`). `super_clipboard` stays out; the channel replaces it.
- Android mDNS relay discovery: the pairing screen browses `_vidyut._tcp` (`RelayDiscovery`, `multicast_dns`) under a WifiManager multicast lock held via the `vidyut/multicast` platform channel, lists nearby relays with a refresh action, and tapping one fills host/port so pairing needs only the secret; QR/manual entry stays as the fallback.
- Reconnect resilience: the relay heartbeats every connection (ping/pong, `heartbeatIntervalMs`/`staleAfterMs`) and terminates sockets whose peer vanished without a close frame; the Android foreground service reconnects on its own with exponential backoff (2s doubling to 60s, reset on success), and the pool re-send that follows every re-auth is deduplicated by origin+timestamp so reconnects do not re-notify the same payload.
- Android in-app debug/log view: an in-memory ring buffer (`DebugLog`, 200 entries) in the UI isolate records connection status, auth results (via the `RelayConnection` events stream), payload events with type/size/origin, send outcomes, and errors; the service isolate forwards its events over the task data channel as `{'kind': 'log'}` messages, and a `DebugLogScreen` (bug icon in the app bar) lists them newest-first with a clear action.
- Flat Raspberry Pink design system applied across all screens: `app/lib/src/design/` holds the palette (raspberry/petal/mist on white, plum ink), Plus Jakarta Sans theme (`google_fonts`, weight-driven 26/16/14/12 scale), spring-motion constants, and the expressive widgets (morphing blob hero, pulsing status dot, ripple-ring success orb, squash-on-press buttons, staggered entrances). Pairing/home, settings, debug log, send-clipboard, and QR screens all use it; looping animations honor `Motion.loopsEnabled` so widget tests settle.
- Home/Settings UX redesign (ADRs `0004`-`0006`): the paired home is a buttonless status dashboard (Connected ring, Last activity, Relay, Setup), Settings is sectioned around the sync switches, and "Forget this laptop" plus the Debug log now live under Settings. Applied on the Flat Raspberry Pink system.
- Relay clipboard read emits exact bytes (`wl-paste --type <mime> -n`): laptop→phone text no longer gains a spurious trailing newline. Verified live on-device.
- New-user setup and day-to-day usage guides: `docs/SETUP.md` (laptop + phone, end to end) and `docs/USAGE.md`.
- The wayfinder map (issue #9) tracks the route to v1 completion; issues #2-#8 are superseded.
- Authenticated relay health reaches the phone and updates live: the home status says
  **Ready** only when the relay and laptop clipboard watcher are healthy, and opens
  actionable recovery guidance when the link is offline or degraded.
- Relay identity uses the laptop hostname in mDNS, pairing QR data, and the paired
  dashboard instead of exposing only an IP address.
- The latest received payload remains latest-only but can be copied again by tapping
  **Last activity**; no clipboard history was added.
- Nearby discovery distinguishes searching, no-laptop, and discovery-failure states
  while keeping QR/manual pairing as the fallback.
- Phone diagnostics persist as a bounded 200-event support trail across app restarts
  and can be copied as a timestamped report.
- In-app updates follow the verified Pomo/Pravah workflow: download the release APK
  to private cache, require and verify its published SHA-256 checksum, request Android's
  per-app install permission when needed, then open the system package installer.

## Verified On-Phone (Seamless Sync E2E)

- The two-direction E2E (`docs/E2E.md` §8-§12) has been run on the real phone + laptop
  over adb, against the relay running as the systemd user service and the redesigned
  debug APK installed on the device.
- **§8-§10 green:** laptop→phone text and phone→laptop screenshot round-trip through the
  redesigned buttonless home/settings UI. Latency well under the 2000ms bar (§9 clipboard
  median ≈935ms; a screenshot round-trip measured 854ms end-to-end). Pairing persists
  across app reinstall.
- The E2E run caught and fixed three real relay bugs (wl-copy pipe stall, JPEG→PNG paste,
  offline-hold startup re-publish), each with a `docs/TROUBLESHOOTING.md` entry.

## Reliability Sign-Off

- **§10.3 / §11 / §12 are accepted through sustained daily use.** The owner has used
  Vidyut for many days without screen-off, reconnect-at-cap, or long-idle failures.
  This continuous real-world soak supersedes the earlier time-boxed test gate.
- D1-D9 and the core two-direction sync behaviour are signed off.

## Latest Verified Commands

```bash
bun run typecheck
bun test
bun run build:relay
./dist/vidyut-relay --help
cd app && flutter test
cd app && flutter analyze
cd app && flutter build apk --debug
```

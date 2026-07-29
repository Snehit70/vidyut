# PRD: Vidyut v1

> Status: ready-for-agent
> Scope: first shippable version — laptop (Linux/Wayland) ↔ Android phone clipboard
> pool over the same WiFi. See `CONTEXT.md` for the glossary and `docs/adr/` for
> the load-bearing decisions this PRD respects (0001 LAN-only relay, 0002
> share-sheet push, 0003 pairing-secret encryption).

## Problem Statement

I take a screenshot on my laptop and want to paste it on my phone a second later —
and vice versa. Today I email it to myself, use a chat app, or fiddle with cables.
Apple's Universal Clipboard does this seamlessly inside its ecosystem; there is no
equally frictionless option for a Linux laptop and an Android phone. It must be
fast to set up so I can hand it to a friend, cost nothing to run, and never leak my
clipboard onto the internet.

## Solution

A single shared clipboard **pool** kept in sync across a user's two **devices** on
the same WiFi:

- The **laptop** runs a small **relay** that holds the current pool **payload** and
  broadcasts new payloads. It watches the system clipboard and publishes new
  images/text automatically; it writes incoming payloads straight into the
  clipboard.
- The **phone** runs a Flutter app. Because Android forbids background clipboard
  reads, the phone publishes via **share-sheet push** (Share → Vidyut, one tap)
  and receives automatically: an incoming payload raises a notification that, when
  tapped, loads the payload into the phone's clipboard, ready to paste.
- **Pairing** is one QR scan; discovery is automatic via mDNS with a manual-IP
  fallback. Every payload is end-to-end encrypted with a key derived from the
  pairing secret, so nothing on the LAN can read it and the relay never sees
  plaintext.

Latest write wins. There is no history.

## User Stories

### Setup & pairing
1. As a user, I want to install the laptop relay as a single binary, so that setup needs no runtime or dependency wrangling.
2. As a user, I want the relay to show a QR code (and a manual code) on first run, so that I can pair my phone in seconds.
3. As a user, I want to install the phone app from an APK, so that I can use it without a Play Store account.
4. As a user, I want to pair by scanning the laptop's QR from the phone, so that setup is one action.
5. As a user, I want a manual IP + secret entry fallback on the phone, so that pairing still works when the QR camera or mDNS fails.
6. As a user, I want the phone to auto-discover the laptop via mDNS, so that it keeps working after the laptop's LAN IP changes.
7. As a user, I want pairing to persist across app restarts and reboots, so that I only pair once per WiFi.
8. As a user, I want to re-pair or reset pairing, so that I can move to a new laptop or revoke a device.
9. As a friend receiving the tool, I want the whole setup to take under two minutes, so that I actually adopt it.

### Laptop → phone (auto-receive)
10. As a user, I want a screenshot I copy on the laptop to be published automatically, so that I don't press any button on the laptop.
11. As a user, I want text I copy on the laptop to be published automatically, so that URLs and snippets reach my phone.
12. As a user, I want my phone to raise a notification when a new payload arrives, so that I know it's ready.
13. As a user, I want tapping the notification to load the payload into my phone clipboard, so that I can immediately paste it.
14. As a user, I want the notification to preview an image thumbnail or the text, so that I know what I'm about to paste.
15. As a user, I want only the latest payload to matter, so that I never wade through history.

### Phone → laptop (share-sheet push)
16. As a user, I want Vidyut to appear in the Android share sheet for images, so that I can push a screenshot in one tap.
17. As a user, I want Vidyut to appear in the share sheet for text, so that I can push a selected link or snippet.
18. As a user, I want a shared payload to land in my laptop clipboard automatically, so that I can paste it without touching the laptop app.
19. As a user, I want a clear success/failure indication after sharing, so that I know whether it synced.

### Connection & resilience
20. As a user, I want the phone to reconnect automatically when WiFi drops and returns, so that sync resumes without my intervention.
21. As a user, I want a visible connection status (connected / searching / offline), so that I can trust the tool.
22. As a user, I want the app to hold the connection via a foreground service, so that Android doesn't silently kill it.
23. As a user, I want the relay to keep serving the last payload to a device that reconnects, so that a device joining late still gets the current clipboard.
24. As a user, I want sane behaviour when both devices copy near-simultaneously (latest timestamp wins), so that the pool is deterministic.

### Security & privacy
25. As a user, I want every payload encrypted end-to-end with the pairing secret, so that other devices on the WiFi cannot read my clipboard.
26. As a user, I want an unpaired/wrong-secret device to be rejected by the relay, so that strangers can't inject or read payloads.
27. As a user, I want nothing to ever leave the LAN, so that my clipboard never touches the internet.
28. As a user, I want the pairing secret stored securely on each device (OS keystore where available), so that it isn't sitting in plaintext.

### Observability & trust
29. As a user, I want really good structured logs on the relay, so that I can diagnose sync failures.
30. As a user, I want a `--verbose`/log-level switch on the relay, so that I can turn up detail when something breaks.
31. As a user, I want the phone app to surface human-readable errors (not stack traces), so that I understand failures.
32. As a developer, I want an in-app debug/log view on the phone, so that I can diagnose issues without a cable.

### Limits & formats
33. As a user, I want large screenshots (multi-MB PNG) to sync reliably, so that fidelity isn't lost.
34. As a user, I want common image formats (PNG, JPEG, WebP) handled, so that any screenshot tool works.
35. As a user, I want a configurable max payload size with a clear message when exceeded, so that a huge file fails loudly, not silently.

## Implementation Decisions

Two components plus a shared contract. No file paths pinned here (see build order in
conversation); modules described by responsibility.

### Relay (Bun daemon, laptop)
- Single Bun process that (a) hosts the WebSocket relay, (b) runs a **clipboard
  watcher** using `wl-paste --watch` for event-driven change detection, (c) runs a
  **clipboard writer** using `wl-copy`, (d) advertises via mDNS `_vidyut._tcp`,
  (e) generates and displays the pairing QR + secret.
- Ships as a compiled single binary via `bun build --compile`.
- Holds exactly one payload in memory (the pool). Latest write wins by timestamp.
- On new client connect (post-auth), immediately sends the current payload so late
  joiners are current.
- The clipboard adapter (watch/read/write) sits behind an interface so it can be
  faked in tests and later ported off Wayland.

### Phone app (Flutter, Android)
- WebSocket client lives inside a `flutter_foreground_task` foreground service.
- Share-sheet receive via `receive_sharing_intent` → encrypt → publish.
- Incoming payload → `flutter_local_notifications` → on tap, write to system
  clipboard via `super_clipboard` (Flutter's built-in `Clipboard` is text-only;
  image clipboard requires `super_clipboard`).
- Pairing via `mobile_scanner` (QR) + manual entry; discovery via `nsd` /
  `multicast_dns`; secret stored in secure storage.
- Connection layer (transport + crypto + clipboard + discovery) behind interfaces
  so UI and business logic are testable without a device.

### Shared wire contract
- Transport: plain WebSocket on the LAN (no TLS — see ADR 0003).
- Auth handshake: client proves knowledge of the pairing secret before any payload.
- Payload frame (JSON): `{ v, type: "image"|"text", mime, origin, ts, nonce,
  payload }` where `payload` is base64 AES-256-GCM ciphertext, key derived from the
  pairing secret, `nonce` per-message.
- Latest-wins conflict rule keyed on `ts`.

## Testing Decisions

Test-driven throughout. Tests assert **external behaviour at the highest seam**, not
implementation details. Preferred seams:

- **Relay protocol seam (highest, preferred):** drive the relay with a real
  in-process WebSocket client. Assert: auth rejects wrong/absent secret; a published
  payload is broadcast to other connected clients; latest-wins overwrites; a late
  joiner receives the current payload on connect; oversized payload is rejected with
  a clear error.
- **Crypto seam:** encrypt→decrypt round-trips for image and text; wrong-key
  decryption fails; tampered ciphertext/nonce fails (AEAD integrity). Pure unit
  tests, no I/O.
- **Clipboard adapter seam:** the `wl-paste`/`wl-copy` adapter tested against a fake
  process boundary so watcher and writer logic are covered without a live compositor.
- **Flutter connection/repository seam:** WS client + crypto + clipboard behind
  interfaces; unit-test publish-on-share and write-on-receive against fakes.
- **Flutter widget tests:** pairing screen, connection-status UI, notification tap →
  clipboard-write flow (fakes for platform channels).
- **One end-to-end manual script** documented in the README: laptop screenshot →
  phone notification → paste; phone share → laptop `wl-paste`.

Definition of "good test" for this repo: fails only when user-observable behaviour
changes; never asserts private function calls or internal state; readable as a spec
of the feature.

## Deliverables

Each deliverable has explicit acceptance criteria. "Done" = all criteria met.

- **D1 — Relay daemon (Bun):** compiles to a single binary; auto-publishes clipboard
  changes; writes incoming payloads; mDNS advertise; QR + secret on first run;
  structured leveled logs; `--log-level` flag; config file for secret/port.
- **D2 — Flutter app (APK):** installable debug APK; share-sheet push (image + text);
  foreground-service WS client; notification → clipboard write; pairing via QR +
  manual; mDNS discovery; secure secret storage; connection-status UI; in-app log
  view.
- **D3 — Shared crypto + wire contract:** AES-256-GCM implemented and cross-verified
  between Dart and TS (a fixture encrypted by one decrypts in the other).
- **D4 — Test suites (TDD):** relay + crypto + adapter tests (Bun test); Flutter
  unit + widget tests. Meaningful coverage of every user-story behaviour above.
- **D5 — Quality bar:**
  - **UI/UX:** clean, minimal, obvious. No dead ends; every state (searching,
    connected, offline, paired, error) has a clear screen/indicator.
  - **No known bugs:** all tests green; the manual E2E script passes both directions.
  - **Logging:** relay emits structured, timestamped, leveled logs; phone has a
    readable in-app log/debug view.
- **D6 — Install & run docs:** `README.md` with exact install/run/pair/test steps for
  laptop and phone, plus the manual E2E verification script.
- **D7 — Repo & version control:** `git init`, sensible `.gitignore` (Flutter + Bun +
  secrets), Conventional Commits history.
- **D8 — GitHub setup:** repository created (`gh`), pushed, description, topics,
  branch protection on `main` (optional), issue tracker enabled with the triage
  label vocabulary so this PRD and follow-ups can be published as issues.
- **D9 — CI pipeline (GitHub Actions):** on push/PR — install toolchains, run relay
  tests, run Flutter analyze + tests, build the relay binary and the debug APK as
  artifacts. Conventional-Commit-titled PRs. Green CI required.

## Definition of Done

1. All D1–D9 acceptance criteria met.
2. Every user story is either implemented or explicitly moved to Out of Scope.
3. `git` + GitHub + green CI in place; APK and relay binary downloadable as CI
   artifacts.
4. A fresh user can follow the README and reach a working laptop↔phone paste in
   under ~two minutes on the same WiFi.
5. The manual E2E script passes in both directions with no known bugs.

## Out of Scope (v1)

- Cross-network sync (different WiFi / cellular) — see ADR 0001.
- Background auto-copy on the phone (Android restriction) — see ADR 0002.
- Clipboard **history** / multiple items — pool is latest-only.
- Arbitrary file transfer was out of scope for v1. It is now designed as the
  next feature in `docs/specs/file-sharing.md` and remains separate from the
  clipboard pool.
- iOS, Windows, macOS clients (Linux/Wayland + Android only for v1).
- X11 laptops (Wayland/`wl-clipboard` only for v1).
- Play Store publishing / signed release APK (debug APK is enough for v1).
- Multi-user shared pools (each user's two devices share a private pool only).

## Further Notes

- Snehit runs Hyprland/Wayland; `wl-clipboard` and Bun are already installed. Flutter
  + Android SDK are **not** yet installed on the machine and are required to build the
  APK (D2).
- The relay component is fully testable on the current machine today
  (laptop↔laptop) before the phone app exists — recommended first milestone.
- Keep `CONTEXT.md` vocabulary in code, logs, and UI copy (pool, payload, relay,
  device, pairing, share-sheet push).

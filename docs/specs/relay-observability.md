# Relay connection observability spec

Resolves [#25 Relay connection observability spec](https://github.com/Snehit70/vidyut/issues/25) on the
[Seamless Sync plan](https://github.com/Snehit70/vidyut/issues/23) map.

## Goal

Make the seamless-sync success bar measurable from the laptop using relay stdout alone:

1. **Screen-on latency** — screenshot on phone → laptop clipboard in ≤2s, measured per payload.
2. **Doze delivery** — payload delivered by next reconnect/wake, measured as reconnect→delivery ordering in the log.
3. **Connection survival** — enough connect/auth/disconnect/reap detail to attribute every drop (MIUI kill vs WiFi drop vs clean close), feeding the phone-survival measurements ticket.

## Format and levels

Use the existing JSON logger (`src/relay/logger.ts`) unchanged: one JSON object per line,
`{ts, level, message, ...fields}`. The `message` field is the event name in `snake_case`
(matching the existing `relay_started` / `relay_stopping`); extra fields are `camelCase`
(matching `maxPayloadBytes`). No payload contents or pairing material ever appear in fields —
sizes and metadata only.

Levels: routine lifecycle and payload flow at `info`; abnormal-but-expected (reaps, auth
failures, protocol errors, stale drops) at `warn`; local failures (decrypt, clipboard write)
at `error`. Nothing observability-critical sits at `debug`, so the default `info` level captures
everything needed to measure the bar.

## Correlation keys

- **`connId`** — 8-hex-char random id assigned at WebSocket upgrade and stored in socket data.
  Required because `deviceId` is unknown until auth and one device reconnects many times;
  `connId` stitches connect → auth → disconnect/reap into one connection story.
- **`frameTs`** — the payload frame's `ts` (origin capture time) plus **`nonce`** identify a
  payload across publish → broadcast → clipboard-write events.

## Event set

### Connection lifecycle (`relay.ts`)

| Event | Level | Fields | Emitted |
|---|---|---|---|
| `device_connected` | info | `connId`, `remote` (ip:port from `socket.remoteAddress`) | `open()` |
| `auth_ok` | info | `connId`, `deviceId`, `msSinceConnect`, `relayProof` (the phone sent a `clientChallenge`), `sealed` | proof verified |
| `auth_failed` | warn | `connId`, `remote`, `reason` (`not_auth_message` \| `proof_rejected`) | before the 1008 close |
| `device_disconnected` | info | `connId`, `deviceId?`, `authenticated`, `durationMs`, `wsCode`, `wsReason` | `close()` |
| `sealed_message_rejected` | warn | `connId`, `deviceId`, `error`, `kind?` | a `sealed` message fails to open (close 1008 `seal_failed`) or a plain control message arrives on a sealed session (close 1008 `seal_required`); ADR 0023 |
| `socket_reaped` | warn | `connId`, `deviceId?`, `idleMs`, `staleAfterMs` | heartbeat sweep terminates a silent socket |
| `client_error_sent` | warn | `connId`, `deviceId?`, `code` (`bad_message` \| `payload_too_large` \| `auth_required` \| `auth_failed`) | every `sendError` |

`msSinceConnect` needs a `connectedAt` timestamp in socket data alongside `lastSeen`.
`socket_reaped` vs `device_disconnected` distinguishes silent peer death (the MIUI-kill
signature) from a close frame; `wsCode`/`wsReason` come from Bun's `close(socket, code, reason)`
callback. A reaped socket logs only `socket_reaped` (terminate may also fire `close`; if it does,
the handler must skip sockets already removed from the device set so each connection ends with
exactly one terminal event).

### Payload path (`relay.ts` + `payload-pool` call sites)

| Event | Level | Fields | Emitted |
|---|---|---|---|
| `payload_published` | info | `connId` \| `origin: "local"`, `deviceId`/`origin`, `type`, `mime`, `bytes` (`encodedPayloadBytes`), `nonce`, `frameTs`, `relayLagMs` (`Date.now() − frameTs`) | pool accepts a frame (phone publish or local clipboard) |
| `payload_stale_dropped` | warn | same identity fields, plus `currentTs` | `pool.publish` returns `false` |
| `payload_broadcast` | info | `nonce`, `frameTs`, `recipients` (authenticated sockets sent to) | after fan-out in the pool subscriber |

`recipients: 0` with a later `device_connected` + replay is the doze-delivery signature
(the relay already replays `pool.current` on auth — that replay send counts as a
`payload_broadcast` with `recipients: 1` and a `replay: true` field).

### Laptop clipboard leg (`clipboard-sync.ts`)

| Event | Level | Fields | Emitted |
|---|---|---|---|
| `clipboard_published` | info | `type`, `mime`, `bytes`, `nonce`, `frameTs` | local clipboard change encrypted + published (start of laptop→phone leg) |
| `clipboard_write` | info | `type`, `mime`, `bytes`, `nonce`, `frameTs`, `e2eMs` (`Date.now() − frameTs`) | remote frame decrypted and written to Wayland clipboard |
| `clipboard_write_failed` | error | `nonce`, `frameTs`, `stage` (`decrypt` \| `write`), `error` | currently swallowed by `Promise.allSettled` — must be caught and logged |
| `clipboard_skipped_paused` | info | `direction` (`publish` \| `write`), `nonce?`, `frameTs?` | a change or an incoming frame ignored because sync is paused |
| `clipboard_paused` / `clipboard_resumed` | info | `until?` / `reason` (`resumed` \| `expired`) | `ClipboardPause` changes (`clipboard-pause.ts`) |

`clipboard_write.e2eMs` **is** the phone→laptop bar measurement: origin capture to laptop
clipboard, one line per screenshot.

## Wiring

`createRelay` and `startClipboardSync` gain an optional `logger: Logger` option (no-op default
so existing tests stay silent); `cli.ts` passes the real logger to both. No wire-protocol or
config changes.

## Measuring the bar

- **Screen-on ≤2s (phone→laptop)**: filter `clipboard_write`, read `e2eMs`.
  `jq -r 'select(.message=="clipboard_write") | .e2eMs'` over relay stdout/journalctl.
- **Laptop→phone**: the relay sees only its half — `clipboard_published` → `payload_broadcast`.
  End-to-end uses the phone's existing debug log (which already timestamps received payload
  metadata): phone receipt time − `frameTs`. No new wire message needed.
- **Doze delivery**: for a payload with `payload_broadcast.recipients: 0`, assert the sequence
  `device_connected` → `auth_ok` → `payload_broadcast{replay: true}` for that device, and report
  `auth_ok.ts − payload_published.ts` as the delivery gap.
- **Clock-skew caveat**: `frameTs` is stamped by the origin device, so cross-device latencies
  are accurate only to inter-device clock sync (NTP-synced devices: typically well under 100ms
  — negligible against a 2s bar). Same-device round-trips are skew-free.

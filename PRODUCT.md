# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

The primary user is one person using a Linux/Wayland laptop and an Android
phone on the same WiFi network. They use Vidyut during ordinary computer and
phone work and want to move clipboard content or files without interrupting
their flow.

## Product Purpose

Vidyut keeps a shared clipboard Payload synchronized between the user's laptop
and phone and supports explicit file Transfers between the paired Devices. The
product succeeds when clipboard sharing happens with minimal intervention,
file sending is quick to start, and the user can understand whether either
operation worked.

## Positioning

Vidyut is a personal, LAN-only, end-to-end-encrypted bridge between a Linux
laptop and an Android phone. It provides near-immediate device-to-device
sharing without sending the user's content through the internet or a cloud
account.

## Operating Context

Pairing happens once over the local network. After pairing, the phone may
receive clipboard Payloads automatically, publish content through the Android
share sheet, and initiate explicit file Transfers. The user may encounter
intermittent connectivity, Android permission restrictions, battery-management
interference, or a temporarily unavailable source file.

## Capabilities and Constraints

- A Relay on the laptop holds the current Pool Payload and broadcasts it to
  paired Devices.
- A Payload is the latest shared clipboard item; Vidyut does not provide
  clipboard history.
- Clipboard synchronization is normally automatic while `Sync with laptop`
  is on. Android's background clipboard restrictions mean that publishing a
  clipboard Payload from the phone may still require an explicit share-sheet
  action.
- A Transfer is an explicitly initiated, durable movement of regular files
  with progress, cancellation, resumability, and local metadata history.
- The phone cannot freely read the Android clipboard in the background, so
  phone-originated clipboard sharing uses explicit user action such as the
  share sheet.
- The system is LAN-only and end-to-end encrypted; no product flow may imply
  cloud sync or an internet dependency.
- The Android app must follow Material 3 structure and Android navigation,
  touch-target, inset, system-back, and motion conventions.
- The canonical user-facing vocabulary is defined in `CONTEXT.md`.
- The first design-system pass includes first-class static light and dark
  themes. Android Dynamic Color is deferred until the branded schemes are
  stable.

## Brand Commitments

- Keep the Vidyut name and existing product truth.
- Refine and systematize the current Android visual identity rather than
  replacing it wholesale.
- The visual system must support automatic clipboard synchronization, fast
  manual file sending, clear connection trust, and actionable recovery;
  decoration must not compete with those jobs.
- The Home surface should prioritize sync status, `Send files`, and latest
  activity. Setup status and relay identity belong in Settings or connection
  details and should not occupy Home during ordinary use.
- `Ready` means the phone is connected and the laptop clipboard watcher is
  healthy enough for automatic clipboard synchronization. A live connection
  with a degraded clipboard path must be presented as `Sync needs attention`.

## Evidence on Hand

- Product overview and operating constraints: `README.md`.
- Canonical domain vocabulary and transfer semantics: `CONTEXT.md`.
- Existing Android design foundation: `app/lib/src/design/`.
- Existing product surfaces: pairing, dashboard, onboarding, setup status,
  activity, Files, Settings, share-sheet push, and diagnostics under
  `app/lib/`.
- No external customer research, testimonials, or performance claims are
  available; future UI must not fabricate them.

## Product Principles

- Make sharing between the user's own Devices feel immediate.
- Make connection and delivery state legible without requiring investigation.
- Make degraded states recoverable with a clear next action.
- Preserve user ownership and local privacy: no cloud assumptions and no
  destructive source semantics.
- Use Android-native interaction patterns while expressing Vidyut's identity
  through a consistent theme and component system.

## Accessibility & Inclusion

- Treat Android system text scaling, touch accessibility, contrast, and reduced
  motion as design-system requirements.
- Validate compact phone layouts and the full range of important operational
  states, including loading, disconnected, permission-blocked, failed, and
  successful sharing.

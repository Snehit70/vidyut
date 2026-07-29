# Vidyut

A personal utility that keeps a single shared clipboard "pool" in sync across a
user's Linux laptop and Android phone on the same WiFi network, so an image
copied on one device can be pasted on the other. Modeled on Apple's Universal
Clipboard, adapted to Android's clipboard restrictions.

## Language

**Pool**:
The single most-recent clipboard payload shared across all connected devices.
Latest write wins; there is no history.
_Avoid_: queue, history, buffer, stack

**Payload**:
One clipboard item synced through the pool — either an image or a text blob,
plus its metadata (type, size, origin device, timestamp).
_Avoid_: item, entry, message, clip

**Relay**:
The small server that holds the current pool payload and broadcasts new payloads
to every connected device. It runs on the laptop and is reachable only over the
local WiFi network; nothing leaves the LAN.
_Avoid_: server, hub, broker

**Device**:
One participant in the pool — currently the Linux laptop or the Android phone.
Each device both publishes and receives payloads.
_Avoid_: client, node, peer

**Pairing**:
The one-time act of pointing the phone at the laptop's relay on the local
network, so the two devices share a pool. This is the entire setup.
_Avoid_: onboarding, registration

**Share-sheet push**:
The phone-to-relay path. Because Android forbids background clipboard reads,
the phone publishes a payload only when the user explicitly shares content
(e.g. a screenshot) into Vidyut via the Android share sheet.
_Avoid_: upload, send

**Forget this laptop**:
The user-facing action that deletes the saved pairing, so the phone no longer
knows any relay and must re-pair (QR or manual) to sync again. Named for its
consequence, like Bluetooth "Forget device". Lives only in Settings, behind a
confirmation (ADR 0005).
_Avoid_: reset pairing, unpair, disconnect

**Sync with laptop**:
The master on/off switch in Settings. On keeps the relay link alive for
clipboard, screenshots, and receive; off disconnects and stops all syncing. It
is the app's power switch, not a notification preference (ADR 0006).
_Avoid_: background sync, persistent notification toggle

**Setup status**:
The persistent checklist of everything that can degrade after pairing
(notifications, photos access, battery exemption, pairing, Xiaomi switches),
each row showing live health and a one-tap fix. The designed recovery surface
for anything skipped in the onboarding wizard.
_Avoid_: permissions screen, diagnostics

**Transfer**:
A durable, explicitly initiated movement of one regular file between the paired
devices. Unlike a clipboard payload, a transfer has progress, pause, resume,
cancellation, a destination, and history.
_Avoid_: file payload, file sync

**Batch**:
The files selected in one send action. Batches wait FIFO and files inside a
batch transfer sequentially.
_Avoid_: folder, archive, pool

**Files**:
The phone and laptop surface for active batches and local transfer history.
History stores metadata only; completed files remain owned by the filesystem.
_Avoid_: library, file manager

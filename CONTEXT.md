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

**Telemetry**:
A live snapshot of the paired laptop's operating state — battery, memory usage,
storage usage, CPU usage, and CPU temperature — shown on the phone without
being retained as history. Telemetry is informational and may be unavailable
when the laptop operating system cannot provide a metric.
_Avoid_: device history, monitoring log, analytics

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
The files selected in one send action. Batches transfer FIFO and files inside a
batch transfer sequentially, though later batches may prepare while they wait.
_Avoid_: folder, archive, pool

**Transfer attempt**:
An immutable offer of the prepared files from a batch that are ready to move.
A later retry may create another attempt without changing the original batch.
_Avoid_: batch, session, retry batch

**Transfer source**:
The byte origin of a file in an unfinished or retryable transfer.
_Avoid_: input file, upload file

**Source reference**:
A durable representation of a transfer source: an external filesystem path,
an external Android document URI, or a managed encrypted stage. Temporary open
handles are not source references.
_Avoid_: file descriptor, reader ID, session handle

**Source ownership**:
Responsibility for a transfer source's lifetime. External sources are never
deleted by Vidyut; managed sources are retained and cleaned with the transfer.
_Avoid_: path type, permission

**Preparation**:
The durable phase that checks and fingerprints a transfer source and, when
necessary, imports it into Vidyut before it is queued for transfer.
_Avoid_: picker import, preprocessing

**Staged source**:
A device-encrypted private copy Vidyut owns temporarily when the selected
transfer source cannot support durable random access. It exists only while a
transfer remains active or retryable.
_Avoid_: cache copy, permanent copy

**Waiting for source**:
A nonterminal preparation condition in which a transfer source is temporarily
unavailable but may become usable without user intervention.
_Avoid_: failed, paused, retrying

**Source changed**:
A terminal condition in which a transfer source no longer has the fingerprint
originally offered for transfer. Its new contents must be sent as a new batch.
_Avoid_: retryable, modified warning

**Expired transfer**:
An unfinished transfer whose seven-day resumability window has elapsed since
its last durable progress, explicit retry, or source replacement. It retains
history but no source resources.
_Avoid_: failed transfer, deleted transfer

**Files**:
The phone and laptop surface for active batches and local transfer history.
History stores metadata only; completed files remain owned by the filesystem.
_Avoid_: library, file manager

**Transfer history**:
The local metadata record of past file batches, including their filenames,
direction, status, progress outcome, and available follow-up actions. It does
not own or delete completed files.
_Avoid_: file library, activity feed, file browser

**Activity**:
A lightweight timeline of meaningful sharing outcomes across Vidyut. It may
include clipboard Payloads, screenshots, and Transfer summaries. Activity is
the quick answer to "what just happened?"; it is not the detailed source of
truth for Transfer progress, recovery, or file actions, which remain in Files
and Transfer history.
_Avoid_: clipboard history, transfer history, debug log

**Activity event**:
One user-visible outcome in Activity, such as a Payload being published or
received, a screenshot being sent, or a file Batch completing with or without
issues. Activity events include meaningful failures when they explain why a
share did not complete, but do not represent every progress update.
_Avoid_: log line, progress tick, notification

**Activity presentation data**:
Optional factual details attached to an Activity event for quick recognition,
such as a filename, media type, dimensions, text excerpt, or preview image.
Missing presentation data is rendered conservatively rather than inferred.
_Avoid_: fabricated metadata, full transfer record

**Activity timeline rail**:
The compact visual sequence connecting Activity events in chronological order.
It communicates recency and outcome without replacing the event cards or
their actions.
_Avoid_: progress bar, transfer queue

**Completed with issues**:
A terminal batch outcome in which at least one file completed and at least one
file did not. The completed files remain available, while unsuccessful files
retain an actionable retry or repair path.
_Avoid_: partially failed, mixed success, incomplete transfer

**Needs attention**:
A Files-surface grouping for transfer states that require user action:
failed, waiting for source, completed with issues, or expired. It is not a
transfer status and does not include ordinary queued, active, or paused work.
_Avoid_: problem transfers, errors only, incomplete

**Ready**:
The user-facing Home state in which the phone is connected to the Relay and
the laptop clipboard watcher is healthy enough for automatic clipboard
synchronization.
_Avoid_: connected only, online, synced

**Sync needs attention**:
The user-facing Home state in which the phone remains connected but automatic
clipboard synchronization is degraded or requires recovery.
_Avoid_: Needs attention, offline, failed

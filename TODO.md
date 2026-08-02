# TODO

## File-transfer performance and UX

Measured baseline and subsequent runs live in
[`docs/file-transfer-benchmarks.md`](docs/file-transfer-benchmarks.md).

### P0 — Recreate the phone transfer receiver after reconnect

- Do not reuse a `PhoneTransferReceiver` after `dispose()` closes its
  `HttpClient`; either create a receiver per relay session or keep the client
  alive until the foreground service itself stops.
- Add a regression test covering disconnect, teardown, reconnect, and a
  subsequent laptop-to-phone transfer with the same service controller.
- Preserve cancellation of the old session's transfer-control subscription and
  any active receive before starting the replacement receiver.

Evidence: on 2026-07-31, two laptop-to-phone attempts for
`rec_2026-07-31_10-24-28.mp4` failed at 0 bytes immediately after a relay
reconnect. The phone's persisted debug log reported `Bad state: Client is
closed` at 10:29:27 and 10:29:53. `ServiceRelayController._teardown()` calls
`PhoneTransferReceiver.dispose()`, which closes its `HttpClient`, but the next
session calls `start()` on that same receiver instance. `_syncOnce()` also runs
this teardown before the initial connection, so even restarting Vidyut closes
the freshly constructed client before its first transfer; restarting either
the phone service or laptop relay is not a workaround. Pairing, relay auth,
receive settings, the 5 GB size limit, and metered-Wi-Fi settings were all
valid, so this is a receiver lifecycle bug rather than a user configuration or
network failure.

Done when a forced relay disconnect/reconnect can receive a file without
restarting Vidyut, repeated reconnects do not leak subscriptions or HTTP
clients, and the regression test fails against the current implementation.

### P0 — Remove mandatory Android picker imports

- Return selected content-URI metadata to Flutter immediately instead of
  copying every file into `cacheDir` before creating the transfer.
- Retain Android read permission for resumable transfers.
- Stream and hash directly from a seekable `ParcelFileDescriptor`.
- Use private staging only when a document provider cannot retain access or
  cannot seek reliably; report staging progress when this fallback is needed.
- Keep the selected source reference durable across process restart and reboot.

#### Android provider/permission research

**SAF contract.** Keep `ACTION_OPEN_DOCUMENT`, `CATEGORY_OPENABLE`, `*/*`, and
`EXTRA_ALLOW_MULTIPLE`; request only
`FLAG_GRANT_READ_URI_PERMISSION | FLAG_GRANT_PERSISTABLE_URI_PERMISSION` (write
is unnecessary). For every URI in `data`/`clipData`, immediately compute
`takeFlags = data.flags & FLAG_GRANT_READ_URI_PERMISSION` and call
`takePersistableUriPermission(uri, takeFlags)` before returning it to Dart.
Android's documented flow requires using the flags actually returned by the
picker, and a taken grant is remembered across reboots; an untaken activity
grant lasts only until reboot. Only an *offered persistable* read/write grant
can be taken, so catch `SecurityException`/provider failure per item rather than
assuming success ([SAF guide](https://developer.android.com/training/data-storage/shared/documents-files#persist-permissions),
[`takePersistableUriPermission`](https://developer.android.com/reference/android/content/ContentResolver#takePersistableUriPermission(android.net.Uri,%20int)),
[`ACTION_OPEN_DOCUMENT`](https://developer.android.com/reference/android/content/Intent#ACTION_OPEN_DOCUMENT)).
A persisted grant survives process death and reboot, but not document
move/deletion, provider/account/USB unavailability, app-data clear, uninstall,
or an explicit release; some grants are unusable until the user unlocks. Store
the URI string, never an fd, reopen it for each hashing/upload session, and
check/open it on resume. Release with `releasePersistableUriPermission(uri,
READ)` only when no unfinished/retryable transfer references that URI (reference
count duplicate selections), such as after completion/cancel/expiry or removal
of the last retryable history item; do not keep grants merely for display-only
history ([persisted-grant APIs](https://developer.android.com/reference/android/content/ContentResolver#getPersistedUriPermissions()),
[`releasePersistableUriPermission`](https://developer.android.com/reference/android/content/ContentResolver#releasePersistableUriPermission(android.net.Uri,%20int))).

**Metadata without copying.** Query an explicit projection containing
`OpenableColumns.DISPLAY_NAME`, `OpenableColumns.SIZE`, and, for document URIs,
`DocumentsContract.Document.COLUMN_LAST_MODIFIED`; use
`ContentResolver.getType(uri)` for MIME. Sanitize the display name as today.
Display name and MIME are required by a conforming `DocumentsProvider`, but a
generic content provider/query can still fail or omit them; `getType` can return
null, so retain extension inference and `application/octet-stream`. Size and
last-modified are explicitly allowed to be null/unknown and provider values can
be stale (especially cloud content); `PFD.statSize` is only a fallback and is
`-1` when the descriptor is not a file. Do not turn null modified time into a
false source-change guarantee: persist it as nullable/unknown and validate by
reopen plus size/hash where available ([document columns](https://developer.android.com/reference/android/provider/DocumentsContract.Document),
[`OpenableColumns`](https://developer.android.com/reference/android/provider/OpenableColumns),
[`getType`](https://developer.android.com/reference/android/content/ContentResolver#getType(android.net.Uri)),
[`getStatSize`](https://developer.android.com/reference/android/os/ParcelFileDescriptor#getStatSize())).

**Random access and fd ownership.** Open read-only with cancellable
`ContentResolver.openFileDescriptor(uri, "r", signal)`. Read mode is allowed to
return a pipe/socket, so neither `CATEGORY_OPENABLE` nor
`ACTION_OPEN_DOCUMENT` guarantees local availability, a regular file, known
length, or seeking. Probe the *opened descriptor* by saving its current offset,
attempting `Os.lseek(fd, 0, SEEK_CUR)` and a harmless seek to the required
offset/back, and treating `ESPIPE`/any seek failure as non-seekable; metadata,
authority allowlists, `statSize`, and successful sequential reads are not
seekability tests ([`openFileDescriptor`](https://developer.android.com/reference/android/content/ContentResolver#openFileDescriptor(android.net.Uri,%20java.lang.String,%20android.os.CancellationSignal)),
[`Os.lseek`](https://developer.android.com/reference/android/system/Os#lseek(java.io.FileDescriptor,%20long,%20int))).
If a provider supplies a subsection, use `openAssetFileDescriptor`; logical
offset zero is `startOffset`, reads must stay within `declaredLength`, and
unknown length is valid. Its typed/read path can also be a pipe, and the owner
must close the `AssetFileDescriptor` ([`AssetFileDescriptor`](https://developer.android.com/reference/android/content/res/AssetFileDescriptor),
[`openAssetFileDescriptor`](https://developer.android.com/reference/android/content/ContentResolver#openAssetFileDescriptor(android.net.Uri,%20java.lang.String,%20android.os.CancellationSignal))).

Do **not** pass a raw integer fd as a durable Dart path. Dart `File`/
`RandomAccessFile` has no public adopt-fd contract, fd numbers are process-local,
and they die on process restart. `detachFd()` transfers close responsibility to
native code and can suppress provider pipe error signalling; `adoptFd()` takes
ownership back and must be the sole closer. If an fd bridge is used within one
live session, detach exactly once, close exactly once (or adopt then close), and
never close the original wrapper afterward
([`ParcelFileDescriptor.detachFd/adoptFd`](https://developer.android.com/reference/android/os/ParcelFileDescriptor)).
The smaller, safer seam is an opaque native `sourceId`/URI handle with Method
Channel operations `probe`, `hashSha256`, `readAt(offset,length)`, `stage`,
`cancel`, and `release`: Kotlin owns each descriptor, applies
`startOffset`, performs seek/read, and closes in `finally`; every operation can
reopen from the persisted URI. This preserves Dart's sender protocol while
replacing its direct `File.stat`, `_hashFile(File)`, and `File.open` calls.

**Fallback and cancellation.** Stage into app-private storage when taking the
grant fails, metadata has no trustworthy non-negative size needed by the offer,
open fails/offline, the descriptor is a pipe/non-seekable, an asset subsection
cannot satisfy random reads, or seek/read probes fail. `FLAG_VIRTUAL_DOCUMENT`
means no byte representation in its advertised MIME and should normally be
rejected or explicitly converted with a typed-open contract, not silently
hashed as the advertised file. `FLAG_PARTIAL` indicates incomplete/downloading
content but is only a hint; actual open/read/probe decides. SAF intentionally
includes cloud and transient providers, so Google Drive/local-provider behavior
must be device-tested rather than inferred from `ACTION_OPEN_DOCUMENT`
([SAF provider model](https://developer.android.com/guide/topics/providers/document-provider),
[`FLAG_VIRTUAL_DOCUMENT`/`FLAG_PARTIAL`](https://developer.android.com/reference/android/provider/DocumentsContract.Document)).
Create the queue card before probing/staging. Stream fallback bytes directly to
a unique private partial file while hashing once, publish byte count/known-size
fraction, and cancel by both `CancellationSignal.cancel()` and checking a shared
cancel token between copy chunks; cancellation must close input/output, delete
the partial, release the grant if now unreferenced, and leave no retryable row
pointing at it. Providers are asked to honor cancellation but may respond late,
so closing resources and ignoring late callbacks are still required
([`CancellationSignal`](https://developer.android.com/reference/android/os/CancellationSignal),
provider cancellation contract in [`ContentProvider.openFile`](https://developer.android.com/reference/android/content/ContentProvider#openFile(android.net.Uri,%20java.lang.String,%20android.os.CancellationSignal))).

**Repo mapping and smallest sequence.** `VidyutFilesPlugin.copyPickedFile`
currently performs the blocking cache import; change `VidyutPickedFile` from
`path/filename/mime` to a durable source reference plus
`uri/filename/mime/size?/lastModifiedMs?/persisted`. Extend
`PhoneTransferSource` to that source abstraction and inject the native reader
behind `PhoneTransferSender`; local/share-intake paths keep a filesystem reader.
Extend `PhoneTransferFile` JSON compatibly with nullable `sourceUri` and source
kind while retaining `sourcePath` for old/local rows. Persist the queued batch
and source URI before hashing, then probe -> direct hash -> offer/read-at; on
fallback, atomically switch that row to a private `sourcePath`, after which the
existing sender/resume logic can continue. On restart, reopen `sourceUri` and
verify grant/access and available metadata before resuming at the receiver's
confirmed offset; never persist a native session/fd. The picker/SAF path needs
no `READ_EXTERNAL_STORAGE` or `MANAGE_EXTERNAL_STORAGE`: user-selected URI
grants provide access. The app's existing legacy `READ_EXTERNAL_STORAGE`
declaration is for the separate screenshot observer and is not justification
for broad picker access ([SAF permissions](https://developer.android.com/training/data-storage/shared/documents-files)).

**Acceptance/tests.** Add: (1) Kotlin contract tests for single/multi-result
flag masking, per-URI take failure, nullable metadata, name sanitization, grant
release/refcount, fd close-on-success/error/cancel, asset offsets, and seekable
versus pipe probes; (2) Dart compatibility tests for old `sourcePath` history
and new `sourceUri`, queue-before-hash, restart reopen/resume at confirmed
offset, direct-reader SHA-256/read-at, atomic stage switch, progress, cancel
cleanup, and source changed/unavailable errors; (3) Android instrumentation
providers returning a regular fd, subsection AFD, unknown-size fd, pipe,
delayed/cancellable pipe, virtual/partial flags, and denied/revoked grants; (4)
physical-device matrix for AOSP Downloads/Media, Google Drive online/offline,
another cloud provider, reboot, force-stop/process kill, moved/deleted source,
locked-boot then unlock, and 1–5 GB files. **Empirical decisions:** whether Drive
returns a seekable cached fd, whether each installed provider promptly honors
cancellation, and whether null/stale size/modified values occur are provider
and version dependent; tests, not authority-specific assumptions, choose direct
versus staging. The 250 ms card target measures picker callback -> persisted
visible row, not completion of metadata, grant, probe, or hash.

Evidence: the current picker blocks while `copyPickedFile` duplicates the
entire file. This delay occurs before the transfer queue exists, is invisible
to the user, consumes source-size temporary storage, and was not included in
the measured 111.479-second RFS transfer.

Done when:

- The Files screen creates a visible queued/preparing card within 250 ms of the
  Android picker returning.
- A seekable 1–5 GB local document begins hashing/transfer without a full
  source-size cache copy.
- Google Drive and other non-seekable providers use a visible, cancellable
  fallback stage.
- Resume still starts at the receiver-confirmed offset after app/process
  restart.

### P0 — Show immediate, truthful preparation progress

- Insert the live transfer card before file metadata, hashing, network policy,
  pairing, or staging work begins.
- Distinguish `Reading selection`, `Staging fallback`, `Verifying`, `Connecting`,
  and `Transferring` rather than grouping all pre-transfer work under an
  indeterminate `Preparing files`.
- Show the current filename, bytes processed, elapsed time, and a cancel action.
- Keep preparation running safely if the user leaves the Files screen.

#### Implementation research

`PhoneTransferSender.enqueue` currently completes `File.stat` and `_hashFile`
for every selection before constructing and saving `PhoneTransferBatch`; before
that, `VidyutFilesPlugin.copyPickedFile` completes the Android cache copy before
`VidyutFiles.pickFiles` returns to `_chooseFiles`. The smallest state change is
to persist each file immediately as `preparing` with a preparation phase
(`reading_selection | staging | hashing | policy_check | connecting`), nullable
size/hash/source metadata, `preparedBytes`, and `preparationStartedAt`; fill
these fields by atomic `TransferHistoryRepository` replacements, then enter the
existing `queued`/send path only when offer metadata is complete. Old JSON
without these nullable fields remains readable. A preparation failure or cancel
must be a terminal persisted transition, not deletion of the card.

The screen is not the work owner: `main.dart` owns the app-scoped
`_transferSender`, while `TransferFilesScreen.dispose` only cancels its progress
subscription. Keep preparation in that service, expose snapshots/replay on
resubscribe, and use a per-file cancellation token checked around source open,
staging/hash chunks, and each awaited setup operation. Cancel closes resources,
deletes only uncommitted staging output, releases an unreferenced URI grant, and
persists `cancelled`; leaving the screen does none of those. No isolate is
required for correctness: Dart file streams and HTTP are already asynchronous,
and the service outlives the screen. An isolate is only a later measured CPU/UI
jank optimization; an Android foreground service is required only if product
semantics promise preparation through app background/process lifecycle, not to
fix navigation. Process death is handled by recovering persisted `preparing`
rows and reopening their durable source references.

Tests: card persisted before stat/hash; phase and byte monotonicity; navigate
away/back during preparation; cancel at source-open/stage/hash/setup; process
kill after each persisted phase; and old-history decoding. The 250 ms visible
target remains an **Empirical decision** measured from picker callback to saved
row, not inferred from API contracts.

Evidence: no state is currently visible after picker confirmation because
Flutter does not receive the selection until native cache copying finishes.

### P0 — Surface exact failure reasons and corrective actions

- Show the durable `errorCode` and a plain-language reason directly on failed
  transfer cards instead of only `Failed`.
- For `file_too_large`, show the file size, the receiver's configured limit,
  and a shortcut to the relevant setting.
- Validate both sender and known receiver limits before staging or hashing when
  possible.
- Preserve the exact receiver rejection in history and benchmark output.

#### Implementation research

Fidelity is lost at three concrete seams. `PhoneTransferSender._errorCode`
collapses most HTTP/socket/format exceptions to `transfer_failed`;
`PhoneTransferReceiver._receiveOffer` collapses all but `file_too_large` and
`hash_mismatch` to `receive_failed`; and Android `publish()` failures become
`publish-failed`, then `receive_failed`. Relay protocol errors also include
`bad_message`, `auth_required`, `auth_failed`, `payload_too_large`, and
`transfer_control_failed`; laptop queue/data-plane paths additionally produce
`insufficient_storage`, `transfer_expired`, `finalization_interrupted`,
`verification_interrupted`, `source_short_read`, `source_unavailable`,
`source_permission_denied`, `chunk_too_large`, `chunk_auth_failed`,
`partial_state_missing`, `destination_short_write`, `hash_mismatch`, and
`terminal_processing_failed`. Free-form remote `transfer_file_failed.code` is
already wire-compatible and TypeScript `TransferFileRecord.errorCode` preserves
it, but Dart history/UI does not preserve enough context.

Extend `PhoneTransferFile` compatibly with nullable `errorOrigin` (`local |
remote | relay`), `errorCategory` (`remote_rejection | local_preparation |
network_policy | source_access | integrity | cancellation | internal`),
sanitized `errorDetail`, and structured `errorContext` values such as
`actualBytes`, `limitBytes`, `phase`, and `retryable`. Keep `errorCode`, preserve
an unknown peer code verbatim, and map it to a generic action rather than
rewriting it. Never persist exception stacks, auth material, filesystem paths,
or content URIs in user-visible detail. The receiver must classify at the catch
site and send that stable code; transport wrappers must retain response
code/body and underlying socket category until this boundary.

Action mapping is data, keyed by category/code: `file_too_large` shows both
sizes and opens the receiving limit setting; `insufficient_storage` opens
storage guidance; permission/revoked/missing/changed source asks to reselect;
offline/timeout/policy offers retry or the metered-network setting;
auth/pairing asks to reconnect/pair; integrity/auth/short-write restarts from a
verified checkpoint; cancellation has no error CTA; unknown/internal offers
retry plus diagnostics. Validate known sender/receiver size and policy limits
before hash/stage, but still treat a later receiver rejection as authoritative
because settings/free space can change. Add round-trip tests for every stable
code, unknown future codes, old history, redaction, and each collapse seam.

Evidence: `The Odyssey.mp4` (3.72 GB) was rejected by the laptop's configured
1 GiB per-file limit before any payload bytes were transferred. The relay
correctly returned `file_too_large`, but the phone history card exposed only
`Failed`, leaving the user unable to diagnose or correct it.

### P1 — Reduce pre-transfer hashing and finalization overhead

- Instrument picker return, source-open, hash start/end, offer/accept,
  first-byte, last-byte, final-hash, and durable-completion timestamps.
- Evaluate hashing while staging only for the fallback path so the same bytes
  are not read once for staging and again for hashing.
- Benchmark whether direct URI hashing can overlap safe setup work without
  weakening whole-file verification.
- Do not remove final receiver-side SHA-256 verification.

#### Implementation research

The current phone sender reads the whole source in `_hashFile` during
`enqueue`, then opens it again and reads every chunk in `_sendFile`; laptop
offers similarly call `TransferCoordinator.hashPath` before
`LaptopTransferDataPlane` rereads chunks. Each receiver writes the plaintext
partial and then rereads the whole partial in its final `hashFile`/
`_hashFile`. These reads are protocol-significant: the offer needs the expected
whole-file digest, and completion must compare the receiver's whole-file digest
before finalization. Keep SHA-256 as specified by [NIST FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final).

Hash bytes while fallback staging to remove only that staging-then-hash read;
persist the digest only after EOF, successful close, and source-size check.
Direct-source hashing may overlap independent pairing, policy/limit lookup,
relay connection, and destination preparation, but the offer must await the
digest and stable size, cancellation must join both branches, and no payload
may be acknowledged against an unfinished digest. Do not hash transmitted
chunks as a substitute: resume can begin at a nonzero offset and ordered hash
state is not persisted by the current protocol. Receiver verification can
stream through an incremental digest as newly written ordered bytes only if a
restart reconstructs the prefix digest by rereading the durable prefix (or a
future authenticated persisted hash state); the simplest unchanged-correctness
implementation retains the final reread.

Add monotonic timestamps at picker return, durable card, source open, stage
start/end, source hash start/end, offer/accept, first/last payload byte,
receiver verify start/end, publish/finalize start/end, and durable completion.
Current history has `createdAt`, `startedAt`, `completedAt`, source mtime, and
confirmed bytes, but not those boundaries; relay events provide only an
approximation for first/last payload. Record durations as monotonic deltas and
wall time only for correlation. **Empirical decision:** whether direct hashing
concurrency improves latency or instead contends for source I/O/CPU; benchmark
serial versus overlapped setup and preserve whole-file hash equality,
source-change, cancellation, resume, and crash-at-EOF/stage-publish tests.

Evidence: the RFS run spent approximately 20.015 seconds outside its measured
active-transfer interval (111.479 seconds end-to-end versus 91.464 seconds
active transfer). The current telemetry cannot yet attribute that overhead
precisely.

Done when the benchmark can separately report selection/staging, source hash,
handshake, active transfer, final verification, and finalization.

### P1 — Coalesce progress work without weakening resume

- Keep per-chunk HTTP acknowledgements for correctness, but throttle UI/control
  progress publication to a time or byte interval.
- Stop opening, synchronously flushing, and closing the destination file for
  every 1 MiB chunk. Keep a bounded transfer writer open and flush durable
  checkpoints at a measured byte/time interval plus pause, disconnect, and
  completion boundaries.
- Evaluate a small bounded pipeline of encrypted chunks so phone read,
  encryption, Wi-Fi upload, laptop decryption, and disk writing can overlap.
  Keep acknowledgements ordered and cap unconfirmed bytes so resume does not
  retransmit an unbounded window.
- Avoid info-level relay logging for every acknowledged chunk; emit periodic
  aggregates and always emit state transitions/errors.
- Measure and reduce receiver queue snapshot writes. Persist safe resume
  checkpoints in batches while reconciling them with the durable partial-file
  length after restart.
- Preserve exact monotonic confirmed offsets and crash-safe finalization.

#### Durability research

Today `PhoneTransferSender._sendFile` is stop-and-wait: read/encrypt/PUT one
chunk, validate the returned offset, then publish progress; it saves sender
history every 4 MiB. The Dart receiver appends one chunk, calls
`RandomAccessFile.flush`, closes, persists history, emits progress, and replies.
The laptop receiver opens, position-writes, calls Node `FileHandle.sync`,
closes, then `TransferQueue.confirmProgress` synchronously rewrites its JSON
snapshot before acknowledgment. Dart documents `flush` as flushing contents
to disk and permits only one pending async operation per handle
([`RandomAccessFile`](https://api.dart.dev/dart-io/RandomAccessFile-class.html),
[`flush`](https://api.dart.dev/dart-io/RandomAccessFile/flush.html)); Node says
`filehandle.sync()` requests data be flushed to the storage device and maps it
to `fsync` ([Node fs](https://nodejs.org/api/fs.html#filehandlesync)). On Linux,
`fsync` flushes file data and associated metadata but not necessarily the
directory entry, so crash-durable create/rename additionally needs the parent
directory synced ([`fsync(2)`](https://man7.org/linux/man-pages/man2/fsync.2.html)).
Close alone is not the durable checkpoint contract.

Define an ACK as `durableOffset`: every byte through it has been written and
flushed/synced, and resume metadata containing exactly that offset has also
been durably replaced; offsets are ordered, monotonic, at most file size, and
never exceed durable partial length. Keep a writer open, accept only contiguous
chunks, and separate volatile `writtenOffset` from `durableOffset`. A bounded
pipeline may have at most `windowBytes` between sent and durable-ACKed offsets;
only durable ACKs advance persisted sender confirmation. On pause, cancel,
disconnect, completion, or writer error, stop admission, drain ordered writes,
checkpoint file then metadata, and ACK only success. After restart reconcile
to `min(valid persisted durableOffset, partial length)`, truncate any tail, and
have the sender retransmit from that offset. Completion remains: size reached,
whole-file SHA-256 matched, destination publication and queue completion made
crash-recoverable; audit the existing link/rename path for parent-directory
sync rather than assuming rename durability.

With the current response contract, pipelined PUTs may remain pending until one
group checkpoint makes all of their contiguous bytes durable, then receive
ordered responses through that same `durableOffset`. Do not return provisional
per-chunk HTTP success for `writtenOffset`: the sender currently interprets a
successful returned offset as confirmed, so doing so would silently weaken
resume unless the wire protocol first gains separate accepted and durable
offsets.

Throttle UI/control/log snapshots independently from durability (latest-value,
at most once/second plus transitions/errors). Snapshot batching must never make
an undurable offset externally confirmed. **Empirical decision:** flush byte/time
interval and pipeline window; API docs establish semantics, not a safe or fast
default. Benchmark each candidate. Tests must kill/crash: before write, mid
write, after write/before flush, after flush/before metadata, after metadata/
before ACK, after ACK, during hash, and before/after publish/queue completion;
also inject short writes, reordered/duplicate chunks, disconnect with a full
window, corrupt/truncated/long partials, and verify bounded retransmission,
monotonic resume, exact hash, and no false completion.

Evidence: the 438.5 MiB RFS run used 1 MiB chunks and generated 439
`transfer_progress` control events. This is close to one event per chunk and
creates avoidable routing, logging, UI, and potentially persistence work.
During the Odyssey run, the laptop had a 433.3 Mbps receive link at -41 dBm and
the relay used only about 12% of one CPU core, while observed chunk
acknowledgements arrived roughly every 0.18–0.4 seconds with occasional
multi-second gaps. The current receiver opens, writes, `fsync`s, and closes the
partial file before acknowledging each chunk; the sender then starts the next
HTTP PUT, making durability latency part of every stop-and-wait cycle.
The 2026-07-30 component audit subsequently reproduced the current laptop
open/write/`fsync`/close pattern at 121.3 MiB/s, so laptop storage is not an
independent 4.5 MiB/s ceiling. Optimize this work as part of the serialized
end-to-end chunk cycle, not as an assumed root cause by itself. The same audit
measured 188.4 Mbps single-stream and 212.3 Mbps parallel-median raw
phone-to-laptop TCP versus Vidyut's 37.9 Mbps active rate.

Done when the same transfer produces at most one user-facing/log progress
update per second while interruption tests prove that no acknowledged durable
checkpoint is skipped on resume. Benchmark throughput and crash recovery for
each flush interval/pipeline window before changing defaults.

### P1 — Make performance comparisons reproducible

- Add a benchmark capture command that records app-stage timestamps, payload
  bytes, Wi-Fi interface RX/TX bytes, relay CPU/RSS, chunk count, retries,
  disconnects, and final SHA-256.
- Write one machine-readable row per run and generate the Markdown comparison
  table from it.
- Label payload-equivalent throughput separately from packet-level wire
  throughput.
- Repeat comparable workloads at least three times and report median and range.

#### Benchmark-method research

Use app-owned monotonic stage timestamps as the authoritative payload clock and
protocol counters as authoritative payload bytes/chunks/retries; relay event
times are fallback approximations, not source-read or socket boundaries. On
Android capture calling-UID RX/TX deltas with
`TrafficStats.getUidRxBytes/getUidTxBytes`: they are network-layer counters,
across all interfaces, monotonic since boot, can return `UNSUPPORTED`, and from
Android N only the calling UID is available
([Android API](https://developer.android.com/reference/android/net/TrafficStats#getUidRxBytes(int))).
Thus they are app/UID-wide, not transfer-, Wi-Fi-, or socket-exclusive. Capture
Wi-Fi interface deltas separately on Linux from
`/sys/class/net/$if/statistics/{rx_bytes,tx_bytes}`; these are interface-wide
`rtnl_link_stats64` values, while `/proc/net/dev` folds some detailed fields
([kernel interface-statistics documentation](https://www.kernel.org/doc/html/latest/networking/statistics.html)).

Sample relay CPU from `/proc/$pid/stat` `utime+stime` divided by elapsed
`_SC_CLK_TCK`, and RSS from `/proc/$pid/status` `VmRSS` (plus peak `VmHWM`),
recording PID/start time so a restart cannot create a false delta
([`proc_pid_stat(5)`](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html),
[`proc_pid_status(5)`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html),
[`sysconf(3)`](https://man7.org/linux/man-pages/man3/sysconf.3.html)). Record
`iw dev $if link` and `adb shell dumpsys wifi` at run start/end as the repo's
existing best-effort RSSI, frequency/channel, BSSID, and negotiated-rate
evidence; retain raw output because Android fields vary by release. SHA-256 is
the protocol's verified completion digest, cross-checkable with `sha256sum`.

Emit JSONL fields `schemaVersion, runId, buildCommit, appVersion, direction,
device/os, workload{name,size,sha256}, protocol{chunkBytes,windowBytes,
flushPolicy}, timestamps{...}, payload{bytes,seconds,bps}, counters{chunks,
retries,disconnects}, androidUid{start,end,supported}, interfaces[{name,
rxStart,rxEnd,txStart,txEnd}], process{pid,startTicks,cpuTicks,rssSamples,
peakRssBytes}, wifi{startRaw,endRaw}, result/errorCode`. Store raw counters,
not only deltas. Reject or flag samples on reboot, PID/interface change, end <
start (reset/wrap), VPN/tethering, or route migration; list all active
interfaces and the route because multi-interface traffic invalidates a single
interface delta. UID deltas include unrelated app traffic and interface deltas
include all host traffic. Report `payload bytes / app active seconds`
separately from `interface byte delta / counter window`; neither is a
packet-capture measure of transfer wire bytes.

Use fixed workload/hash, direction, devices, power/thermal state, SSID/BSSID,
distance, build, policy, chunk/window/flush settings, and run order; include a
warm-up then at least three measured runs, reporting median and min–max plus all
rows. **Empirical decision:** required repetitions beyond three and acceptable
thermal/radio variance, based on observed dispersion.

Evidence: run 002 captured payload timing and process resources, but its
OS-interface counters were not reliable and the original 14-file baseline did
not retain stage or resource measurements.

### P2 — Re-evaluate negotiated chunk size after instrumentation

**Complexity: high. Status: design discussion required before implementation.**
This is no longer only a four-value benchmark task: making transfer parameters
reactive would affect protocol capability negotiation, concurrency, durability,
memory bounds, pause/cancel latency, resume behavior, diagnostics, and persisted
learning. Do not implement an adaptive controller from these notes alone.

- Compare 1, 2, 4, and 8 MiB chunks on the same phone, laptop, Wi-Fi, and file.
- Measure throughput, memory, encryption time, resume retransmission cost, and
  failure behavior before changing the 1 MiB default.
- Keep negotiation and the legacy 256 KiB fallback compatible.

#### Adaptive-transfer discussion notes (unresolved)

The initial question was whether chunk size could increase while transfers are
stable, decrease when problems appear, and fluctuate below a ceiling. The
discussion established an important distinction but did **not** settle the
design:

- **Chunk size** is the plaintext represented by one encrypted HTTP request.
  Increasing it reduces request/control overhead but increases buffer memory,
  allocation pressure, per-request latency, pause latency, and retransmission
  cost after interruption.
- **In-flight window** is the bounded request count and byte total sent but not
  yet durably acknowledged. Adapting this may recover more throughput than
  resizing chunks, but it introduces receiver concurrency and checkpoint
  semantics that the current stop-and-wait protocol does not have.
- **Negotiated maximum chunk size** is a compatibility/safety ceiling, not
  evidence that the maximum is the fastest or safest operating size.
- A possible future **adaptive transfer profile** would contain the fixed chunk
  size chosen for a batch, current request-count tier, maximum unconfirmed byte
  budget, confidence, and direction-specific learned hints. This is proposed
  vocabulary, not an accepted data model.

Provisional preferences from the discussion were a balanced objective rather
than maximum throughput; fixed chunk size within a batch; tiered window changes;
explicit peer capability negotiation; durable confirmed offsets only; separate
request-count and byte ceilings; batch-owned live state; combined promotion
evidence; immediate hard-failure demotion; at most one cooldown retry after a
soft regression; direction-specific learned hints with confidence decay; and
diagnostic visibility without user tuning controls. Prefer the smallest tier
that achieves near-peak throughput rather than the highest tier that happens to
survive. These preferences need validation together and must not be treated as
an implementation-ready specification.

The discussion stopped without deciding whether later batches should learn a
chunk size or always use the negotiated maximum. Choosing the maximum can lower
HTTP/control overhead while increasing memory, ACK latency, pause latency, and
bounded-retransmission exposure; choosing among sizes requires measurements.
More detailed design work must resolve:

1. Whether adaptive scope includes chunk size, in-flight window, or both, and
   whether each parameter changes within a file, between files, or only between
   batches.
2. The receiver capability fields and compatibility behavior for old peers.
3. The exact durable-ACK/checkpoint contract for multiple pending PUTs, including
   crash points and whether pending requests wait for a grouped checkpoint.
4. Memory, request-count, unconfirmed-byte, pause-time, and retransmission
   ceilings on each device class.
5. Promotion/demotion signals, stability intervals, anti-oscillation rules,
   confidence decay, invalidation, and the minimum meaningful throughput gain.
6. Whether learning belongs to a device-direction profile, how it is persisted,
   and how stale network conditions are prevented from producing unsafe warm
   starts.
7. A staged rollout that changes one control at a time so chunk-size and window
   effects remain attributable, with a kill switch and legacy fallback.

Required next step: hold a dedicated protocol/design review after baseline
instrumentation exists, model concrete pause/disconnect/crash/retry scenarios,
then record the selected invariants in an ADR before changing the wire protocol.

#### Experiment research

`TransferChunkPolicy.negotiate` currently chooses the minimum valid local and
peer advertised maxima; a missing/invalid peer value falls back to 256 KiB.
The Dart sender caps each PUT at that negotiated size, while the TypeScript
data plane enforces the same cap. Preserve that wire behavior and tests for an
old peer, asymmetric maxima, invalid advertisements, and an oversized request;
experiments change advertised local maxima/configuration, not the legacy
fallback or receiver validation.

Run a randomized/counterbalanced matrix of 1, 2, 4, and 8 MiB chunks crossed
with each candidate fixed pipeline window/flush policy, including stop-and-wait
as control, on the same immutable large-file SHA-256, direction, phone, laptop,
build, BSSID/channel/location, power/thermal state, and background-traffic
rules. Use at least one sustained multi-GiB file and a smaller-file workload so
startup/finalization is not hidden. Repeat each cell at least three times and
report every run plus median and min–max for active/end-to-end payload
throughput, first-byte latency, per-stage read/encrypt/HTTP/decrypt/write/sync
time, CPU, peak RSS, allocations/GC if available, requests/chunks, retries,
disconnects, durable-ACK latency, progress gaps, final verify time, and
interface/UID deltas.

Bound memory by measured peak plus an explicit worst-case budget for plaintext,
ciphertext, HTTP buffering, receiver buffers, and `windowChunks * chunkBytes`;
bound crash/disconnect retransmission by `windowBytes` and time-to-recover.
Inject disconnects at each chunk size/window, lost responses after durable
write, timeout/retry, process kill, low storage, short write, and integrity
failure; require no offset regression, duplicate corruption, unbounded retry,
or hash mismatch. Promote a size only if its repeated median materially improves
the fixed baseline without regressing end-to-end latency, memory budget,
durable-ACK tail latency, recovery success, or bounded retransmission on either
direction/device class. **Empirical decision:** the winning size, pipeline
window, flush interval, and material-improvement threshold; choose none until
instrumented measurements exist.

Larger chunks may reduce request/encryption/control overhead, but no chunk-size
gain is proven by the current run, so this remains behind the measured P0/P1
work.

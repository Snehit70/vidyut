# Android picker selections are durable transfer sources

Android system-picker selections must enter the durable transfer module as
source references, not as mandatory plaintext cache imports. Copying every
selection before a transfer row exists makes large picks appear frozen, doubles
their storage, and prevents preparation, cancellation, and recovery from sharing
the transfer lifecycle defined by ADR 0007.

## Decision

A user selection creates and persists a visible Batch and its logical files
before metadata lookup, hashing, probing, or staging. Preparation is owned by
the durable Android transfer service, continues after the Files screen closes,
and recovers when the service restarts. The picker synchronously attempts the
persistable read grant and then returns the URI; provider metadata is populated
during preparation so a slow provider does not delay the visible row.

Every logical file has one of three durable source representations:

1. an external filesystem path;
2. an external Android document URI; or
3. a Vidyut-managed encrypted stage.

Each reference records source ownership. Vidyut never deletes external sources
and cleans managed sources with the transfer lifecycle. Raw file descriptors,
native reader IDs, and open sessions are process-local and are never persisted.
Kotlin owns descriptor open, seek, read, cancellation, and close behind native
source-reader operations; Dart never adopts an integer file descriptor.

Provider metadata is advisory. Size and modified time remain nullable, and
modified time is never part of source identity. Content identity is exactly
size plus SHA-256. Direct reading is allowed only when access is durable, size
is known, and actual open, seek, and read probes succeed. Provider names, MIME
types, document flags, descriptor stat size, and successful sequential reads do
not imply random access.

The preparation decision is explicit:

- **Direct** when durable access, known size, and random access all succeed.
- **Stage** when bytes are readable now but durable permission, known size, or
  random access is missing.
- **Waiting for source** when persisted access exists but a temporary provider,
  account, network, or device-lock condition prevents reading.
- **Source unavailable** for deletion, definitive revocation, unsupported
  virtual documents, or expired access.

If grant persistence fails but temporary access still works, staging starts
immediately. If the source cannot then be read, it requires reselection rather
than pretending it can recover after restart. Staging encrypts bytes at rest
with a device-local key and exposes random reads only through the source reader.
Incomplete stages are deleted on cancellation, pause, or interruption; staging
restarts from byte zero.

## Batch, attempt, and resume semantics

A Batch is the stable set of logical files selected in one user action. A
Transfer attempt is its durable immutable wire offer containing the files that
were prepared when the Batch reached the head of its device-local outgoing
queue. An Attempt owns its protocol transfer ID and receiver-confirmed offsets.
Relay reconnects, process restarts, and retryable transport interruptions resume
the same Attempt; files prepared after it was sealed use a later Attempt.

Outgoing transfer order is strict FIFO per originating device, not a global
order across both directions. Later batches may prepare while they wait, but a
paused or waiting head Batch blocks younger outgoing attempts. Incoming and
outgoing work may coexist. The durable transfer service is the sole Android
scheduler and state-transition authority.

The first sealed Attempt freezes a logical file's content identity. A direct
source whose native session was lost is reopened and rehashed before resume. A
receiver hash mismatch causes one local revalidation: matching source bytes are
an integrity failure eligible for one restart from zero; different source bytes
are terminal **Source changed** and must be sent as a new Batch.

Preparation failure for one file does not prevent prepared files from moving.
Later **Retry failed** work creates another immutable Attempt associated with
the original Batch. File and Batch pause, resume, cancel, and retry remain part
of the transfer-module boundary. Batch status is derived from file states rather
than advanced independently.

## Resource and compatibility rules

URI grants are reference-counted across unfinished and retryable logical files.
Each file has a seven-day retry window measured from durable progress or an
explicit retry/replacement; backoff, observation, startup, and pause/resume do
not extend it. Completion, cancellation, expiry, or removal releases
unreferenced grants and managed stages. Completed history retains metadata and
may retain a non-owning external resend hint, but never owns a grant or managed
stage solely for **Send again**.

Old history containing only `sourcePath` remains readable as an external path.
The old app-private `vidyut-picker` namespace is an unambiguous managed legacy
source. Nullable modified time is represented canonically in history; compatible
wire messages retain the numeric field with an explicit validity marker, and
receivers apply modified time only when known.

This decision applies to Android system-picker selections. Share-intake URI
migration, provider-specific allowlists, virtual-document conversion, and
changes to the clipboard pool are out of scope. Provider seekability and
cancellation responsiveness remain empirical device-test results, never
authority-based policy.

## Consequences

The transfer persistence model must distinguish logical Batches, immutable
Attempts, source representation, source ownership, retry eligibility, and
attempt-scoped progress. Android must move outgoing execution out of the Files
widget and into the durable service. This is more structural work than returning
a URI from the picker, but it avoids persisting process-local handles, plaintext
stages, mutable wire manifests, and history rows that outlive the resources they
silently depend on.

# TODO

## Current scope

Measured transfer baselines live in
[`docs/file-transfer-benchmarks.md`](docs/file-transfer-benchmarks.md).
The detailed P1 hashing/finalization handoff is in
`/tmp/imagesync-task-p1-hashing-finalization-handoff.md`.

## Next PR and device validation sequence

- This PR adds Android picker grant-contract hardening and JVM coverage. Review
  the branch before merging it.
- After merge, install the merged debug APK on the connected Android phone,
  then verify the phone is paired with the latest relay/app build.
- Run the provider matrix against the latest app: AOSP files/media, Google
  Drive online/offline, another cloud provider, reboot/force-stop,
  moved/deleted sources, locked boot, and representative large files.
- Capture the fixed transfer workloads with the benchmark command and record
  preparation, hashing, handshake, active transfer, verification/finalization,
  progress events, checkpoints, retries, disconnects, SHA-256, device/build,
  network counters, and relay CPU/RSS. Repeat each scenario at least three
  times and report median/range.
- Do not mark physical provider behavior or performance acceptance complete from
  code review or unit tests alone; update this file with device evidence after
  the post-merge run.

## Completed implementation

- **Receiver lifecycle after reconnect** — `d728e6e`, `e778e93`.
  Receiver instances are recreated per relay session and old receives are
  aborted during teardown.
- **Durable Android picker sources** — `4da76b2`.
  Picker selections return URI metadata, grants are retained, seekable sources
  use direct reads, and non-seekable sources use managed staging.
- **Actionable failure reasons** — `49ad666`.
  Error codes, origins, categories, details, and corrective UI actions are
  persisted and displayed.
- **Immediate preparation progress core** — `6330653`, `e26ae3e`.
  Preparation rows are durable before source work, phases and byte progress are
  published, work is sender-owned across navigation, cancellation is persisted,
  and history writes are serialized.
- **P1 hashing/finalization implementation core** — current work.
  Timing spans now cover sender preparation through durable completion; fallback
  staging computes the digest in the copy pass; direct-source relay setup can
  overlap hashing while offer publication remains digest-gated; native staging
  cancellation invalidates the in-flight operation; receiver SHA-256 remains
  required.
- **Benchmark capture command** — current work.
  `bun run benchmark:capture` emits JSONL or CSV rows and can generate a
  median/range Markdown stage summary from persisted queue timing data. Device,
  build, network, disconnect, and relay resource fields are explicit metadata
  inputs and remain null when not captured.
- **P1 progress coalescing implementation** — current work.
  Receiver accepted offsets are volatile and separate from durable queue
  checkpoints; checkpoints occur at 4 MiB or 1 second, routine progress is
  throttled, same-file PUTs serialize, restart resumes from the durable offset,
  and pause/cancel checkpoint before changing terminal state.
- **Cancelled retry and transfer status UI** — current branch.
  Cancelled phone-to-laptop batches reactivate as a fresh laptop attempt on a
  repeated offer, completed live progress renders as complete, and active
  cancellation uses state-aware wording.

## Remaining P0 acceptance work

### Android source/provider validation

- Add Kotlin contract and Android instrumentation coverage for persistable
  grants, metadata gaps, regular files, asset subsections, pipes,
  cancellation, revoked sources, and managed-stage cleanup.
- Run the physical matrix: AOSP files/media, Google Drive online/offline,
  another cloud provider, reboot/force-stop, moved/deleted sources, locked boot,
  and 1–5 GB files.
- Record whether each provider is seekable and cancellation-responsive; do not
  infer provider behavior from static SAF contracts.

### Preparation progress acceptance

- Add race/crash tests for every preparation phase, pending cancellation,
  source unavailability, partial batches, retry, and nonzero resume offsets.
- Verify navigation away/back replays the current snapshot without starting a
  second worker.
- Measure the picker callback → durable visible card target: p95 ≤250 ms over
  at least 30 profile/release runs on the lowest supported reference device.
- Keep code-test, benchmark, and physical-device results reported separately.

## P1 — Reduce pre-transfer hashing and finalization overhead

- Acceptance still needs benchmark output that separately attributes picker
  selection/staging, source hash, handshake, active transfer, final
  verification, and finalization.
- Compare serial versus safe-overlapped direct-source hashing/setup in measured
  runs. Offers must still wait for a complete digest and stable size, and
  cancellation must invalidate both branches.
- Keep final receiver SHA-256 verification unless a restart-safe persisted hash
  state is designed and proven.

Evidence: the RFS run had about 20.015 s outside active transfer; the Odyssey
run spent 22.315 s in final verification/finalization. Existing audit data puts
phone pre-offer hashing around 23–26 MiB/s.

## P1 — Coalesce progress work without weakening resume

- Measure the implemented bounded checkpoint/publication policy against the
  previous per-chunk persistence behavior.
- Evaluate a long-lived writer or bounded encrypted-chunk pipeline only as a
  separate follow-up with explicit durable-ACK, memory, retransmission, and
  crash-recovery guarantees.

Acceptance: at most one user-facing/log update per second in comparable runs,
without skipping any acknowledged durable checkpoint after interruption.

## P1 — Make performance comparisons reproducible

- Use `bun run benchmark:capture -- --queue <transfers.json>` to produce rows
  with stage timings, payload bytes, retries, disconnects, SHA-256,
  device/build, network counters, and relay CPU/RSS metadata.
- Generate the Markdown stage summary with `--markdown <path>`; the remaining
  comparison work is to combine fixed before/after workloads.
- Repeat fixed workloads at least three times and report median and range.

## P2 — Re-evaluate negotiated chunk size

Design discussion remains required before implementation. Compare 1, 2, 4,
and 8 MiB under the same device/Wi-Fi/file conditions, measuring throughput,
memory, encryption time, resume retransmission cost, and failures. Preserve
negotiation and the legacy 256 KiB fallback; do not build an adaptive controller
from benchmark notes alone.

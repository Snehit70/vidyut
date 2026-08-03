# File transfer benchmarks

This table tracks physical phone-to-laptop transfers over the same local Wi-Fi
network. Keep end-to-end throughput separate from the active transfer rate:
preparation, hashing, negotiation, and final verification are included only in
the end-to-end measurement.

The timestamped raw-LAN and component ceiling audit is
[`benchmarks/2026-07-30-lan-throughput-audit.md`](benchmarks/2026-07-30-lan-throughput-audit.md).

| Run | Build | Workload | Result | Total size | End-to-end time | End-to-end throughput | Active transfer time | Active transfer throughput | Retries/errors | Laptop relay memory | Laptop relay CPU |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 001 — original baseline | pre-v1.3.1 | 14 APK files | 14/14 completed | 1.795 GiB | 10m 19.9s | 2.964 MiB/s (24.87 Mbps) | Not captured | Not captured | Not captured | Not captured | Not captured |
| 002 — RFS single file | v1.3.1 (`55a4119`) | `Rfs_-_Real_Flight_Simulator_3.2.4_1784591704_latestmodapks.com.apk` | 1/1 completed; SHA-256 verified | 438.5 MiB (459,803,116 bytes) | 1m 51.479s | 3.933 MiB/s (32.997 Mbps) | 1m 31.464s | 4.794 MiB/s (40.217 Mbps) | 0 retries; 0 warnings/errors | 81.5 MiB average; 105.1 MiB peak | 15.15% of one core average |
| 003 — Odyssey single-file retry | v1.3.1 (`55a4119`) | `The Odyssey.mp4` after raising the laptop limit to 5 GiB | 1/1 completed; SHA-256 verified | 3.468 GiB (3,724,079,838 bytes) | 13m 31.984s | 4.374 MiB/s (36.691 Mbps) | 13m 6.872s | 4.514 MiB/s (37.862 Mbps) | 0 transfer retries; 0 warnings/errors | 86.4 MiB average; 139.1 MiB peak | 16.83% of one core average |

## Relative result

Run 002's end-to-end throughput was 32.7% higher than run 001's aggregate
throughput. This is directional rather than an apples-to-apples regression
result because run 001 contained 14 files and run 002 contained one file.

Run 003's end-to-end throughput was 47.6% higher than run 001's aggregate
throughput and 11.2% higher than run 002's end-to-end throughput. Its active
transfer throughput was 5.9% lower than run 002's. The larger workload makes
run 003 the stronger sustained-throughput baseline, but it was a retry of an
already staged source and therefore does not include Android picker import or
initial source hashing.

The RFS timing breakdown was:

- Queue created to durable completion: 111.479 seconds.
- Transfer offer to durable completion: 94.919 seconds.
- First progress event to durable completion: 91.464 seconds.
- Preparation, negotiation, and finalization outside the active transfer
  interval: approximately 20.015 seconds.
- Completion SHA-256:
  `1fe5c0d7381068d09bede17e5906fe207856b44cc878e6930648d023fe267840`.

The Odyssey retry timing breakdown was:

- Transfer accept to durable completion: 811.984 seconds.
- First to last progress event: 786.872 seconds.
- Handshake/first-chunk time before the first progress event: 2.797 seconds.
- Final receiver verification and finalization after the last progress event:
  22.315 seconds.
- Largest gap between progress events: 16.287 seconds.
- Progress-control events: 3,552 for a 1 MiB negotiated chunk size.
- Laptop Wi-Fi RX during the measured window: 3,903,283,600 bytes, or
  4.584 MiB/s averaged across the 812-second window. This includes protocol and
  unrelated interface traffic, so it is not the payload throughput.
- Completion SHA-256:
  `c595ce93e61b4d35e4195c88b6c26177688341d921852c4048f9d628651e1614`.

The Android picker-to-cache import happens before the Flutter transfer queue is
created, so its duration is **not included** in run 002. Future measurements
must capture picker confirmation time separately until direct content-URI
streaming removes that staging step.

Run 003 also excludes picker import because it retried the previously rejected
Odyssey history entry after the laptop's per-file limit changed from 1 GiB to
5 GiB. The earlier rejection was `file_too_large` and transferred no payload
bytes.

## Measurement notes

- Run 001 values were transcribed from the original on-device baseline result.
- Run 002 queue timestamps came from `~/.config/vidyut/transfers.json`.
- Run 002 active-transfer boundaries came from the relay's first
  `transfer_progress` and `transfer_file_complete` events.
- Relay process RSS and CPU were sampled every two seconds. CPU uses the
  machine's 100 Hz process clock.
- The receiver produced 439 progress-control events for this 438.5 MiB file.
  This should be tracked because excessive progress persistence/logging can add
  avoidable overhead.
- OS network-interface byte counters were not retained reliably for run 002;
  the reported Mbps values are payload-equivalent rates, not packet-capture
  wire rates.

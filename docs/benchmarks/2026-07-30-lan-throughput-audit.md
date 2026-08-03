# Vidyut LAN throughput audit — 2026-07-30

Test window: **2026-07-30 21:27:55–21:45:11 IST**  
Direction names: **phone → laptop** matches the measured Vidyut uploads.

## Executive result

The current Wi-Fi path has three distinct ceilings:

| Ceiling | Phone → laptop result |
| --- | ---: |
| Negotiated PHY ceiling | 433 Mbps / 54.1 MB/s |
| Best measured TCP payload sample | 218.7 Mbps / 27.3 MB/s |
| Repeatable single-stream TCP median | 188.4 Mbps / 23.5 MB/s |
| Vidyut Odyssey active-transfer rate | 37.9 Mbps / 4.73 MB/s |

Vidyut currently uses **20.1% of the measured single-stream TCP median** and
**17.8% of the highest repeatable parallel median**. The present implementation
is therefore application/protocol limited, not radio-, storage-, laptop-CPU-,
or laptop-crypto-limited.

The defensible target on this exact unchanged Wi-Fi setup is:

- **First optimization target:** 150–180 Mbps (18.75–22.5 MB/s).
- **Low-latency measured ceiling:** approximately 188 Mbps (23.5 MB/s) with one
  TCP stream.
- **Maximum measured bulk ceiling:** approximately 212–219 Mbps
  (26.5–27.3 MB/s), with high-stream tests showing materially worse latency
  and unstable retransmissions.

This replaces the earlier unmeasured estimate that 30–35 MB/s should be
reachable. The measured path did not sustain that rate.

## Test environment

### Phone

- Xiaomi `M2101K6P` (`sweetin`), Qualcomm SM7150.
- Android 13 / API 33.
- 7.39 GiB physical RAM; approximately 9.4 GB free shared storage.
- Vidyut 1.3.1, version code 2013; updated 2026-07-30 20:47:21 IST.
- Wi-Fi 5, 5 GHz channel 44, 80 MHz.
- Negotiated and maximum reported TX/RX: **433 Mbps**.
- Signal during tests: **-35 to -41 dBm**.

### Laptop

- Fedora, kernel `7.0.10-201.fc44.x86_64`.
- Intel Wireless 8265/8275, Wi-Fi 5, 2x2-capable.
- Incoming negotiated rate during tests: **433.3 Mbps**, VHT MCS 9, 80 MHz,
  one spatial stream.
- Outgoing negotiated rate: **866.7 Mbps**, VHT MCS 9, 80 MHz, two spatial
  streams.
- Signal during tests: approximately **-40 dBm**.
- 512 GB SATA SSD; Btrfs with zstd level 1 compression.
- Vidyut relay build: v1.3.1 at commit `55a4119`.

Both devices used SSID `NetXpress`, BSSID `92:ca:e7:ae:60:da`. Traffic passed
through the access point; this was not Wi-Fi Direct.

## Raw TCP throughput

Each cell is three 12-second runs after a two-second warm-up. Throughput is the
receiver result. Full per-run values are in the adjacent CSV.

| Direction | Streams | Minimum | Median | Maximum | Median MB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Laptop → phone | 1 | 122.1 Mbps | 134.4 Mbps | 134.7 Mbps | 16.81 |
| Laptop → phone | 2 | 139.7 Mbps | 140.5 Mbps | 141.5 Mbps | 17.57 |
| Laptop → phone | 4 | 138.0 Mbps | 138.9 Mbps | 140.3 Mbps | 17.36 |
| Laptop → phone | 8 | 136.0 Mbps | 136.9 Mbps | 137.0 Mbps | 17.11 |
| Phone → laptop | 1 | 179.1 Mbps | 188.4 Mbps | 190.7 Mbps | 23.55 |
| Phone → laptop | 2 | 200.6 Mbps | 203.5 Mbps | 208.8 Mbps | 25.44 |
| Phone → laptop | 4 | 202.7 Mbps | 205.5 Mbps | 212.8 Mbps | 25.69 |
| Phone → laptop | 8 | 201.1 Mbps | 212.3 Mbps | 218.7 Mbps | 26.54 |

Concurrency produces diminishing returns:

- Phone → laptop improves 8.0% from one to two streams.
- Two to four streams adds only 1.0%.
- Four to eight streams adds 3.3%, while loaded latency and retransmissions
  become substantially worse.

## Latency and load behavior

- Idle LAN ping: 0% loss, 4.16 ms average, 18.21 ms maximum.
- Phone → laptop, one stream under load:
  - 157.1 Mbps in the loaded-latency run.
  - 13.07 ms average ping, 29.48 ms maximum.
  - 0% ping loss.
- Phone → laptop, four streams under load:
  - 205.2 Mbps.
  - 98.79 ms average ping, 165.84 ms maximum.
  - 0% ping loss but 3,220 TCP retransmissions reported by the sender.

The four-stream result is useful for bulk ceiling discovery but is not a good
default product operating point. Start Vidyut optimization with a bounded
two-chunk pipeline and measure responsiveness before widening it.

## UDP loss and jitter

Phone → laptop was clean at 150 Mbps:

- 150.0 Mbps received.
- 0.029% packet loss.
- 0.048 ms jitter.

At a 200 Mbps target:

- 185.2 Mbps received.
- 2.05% packet loss.
- 0.043 ms jitter.

Higher requested rates produced non-monotonic 141–184 Mbps receiver results.
The phone bundles iperf 3.6+, so use the UDP sweep as a low-loss floor and
overload indicator, not as the primary ceiling. TCP medians are the principal
capacity measurement.

## Storage, hashing, crypto, and USB controls

These controls rule out several possible bottlenecks:

| Component | Measured result | Interpretation |
| --- | ---: | --- |
| Phone 512 MiB sequential write | 181 MB/s | Far above Vidyut |
| Phone cached 512 MiB read | ~1.0 GB/s | Cache-influenced; not a storage floor |
| Phone SHA-256 over 512 MiB | ~394 MB/s | Native shell hash is not limiting |
| Vidyut phone pre-offer hash window, RFS | 26.48 MiB/s | Adds preparation latency |
| Vidyut phone pre-offer hash window, Odyssey | 23.34 MiB/s | Adds ~152 s before first offer |
| Laptop current-style 1 MiB open/write/fsync/close microtest | 121.3 MiB/s | Per-chunk sync is inefficient but SSD capacity alone does not explain 4.5 MiB/s |
| Laptop AES-GCM encryption | 333.3 MiB/s | Not limiting |
| Laptop AES-GCM decryption | 664.9 MiB/s | Not limiting |
| Odyssey receiver final SHA-256/finalization | 22.315 s / ~159 MiB/s | End-of-transfer latency, not active-rate ceiling |
| USB 2.0 ADB push, laptop → phone | 34.5 MB/s | Wired reference, not Vidyut transport |
| USB 2.0 ADB pull, phone → laptop | 33.6 MB/s | Wired reference, not Vidyut transport |

The phone negotiated USB 2.0 at 480 Mbps. ADB sustained about 269–276 Mbps.
This demonstrates a faster wired path, but ADB throughput does not predict USB
Ethernet or a future Vidyut USB transport exactly.

## Vidyut comparison

The 3.468 GiB Odyssey retry completed with:

- 4.514 MiB/s active payload throughput (37.862 Mbps).
- 4.374 MiB/s accept-to-durable-completion throughput.
- 3,552 progress events for 1 MiB chunks.
- 22.315 seconds final verification/finalization.
- 16.287 seconds largest progress-event gap.
- 16.83% average laptop relay CPU and 139.1 MiB peak RSS.
- Zero transfer warnings/errors and a verified final SHA-256.

At the measured raw network rates, the same 3.468 GiB payload would take:

- About **2m 38s** at the 188.4 Mbps single-stream median.
- About **2m 20s** at the 212.3 Mbps parallel median.
- About **2m 16s** at the 218.7 Mbps best sample.

Those are network-only lower bounds. Vidyut must still encrypt, durably
checkpoint, verify, and finalize. A realistic initial optimized target of
150–180 Mbps implies roughly **2m 46s–3m 19s active transfer**, plus preparation
and final verification, instead of the current 13m 7s active transfer.

## Bottleneck conclusion

Ranked by current evidence:

1. **Serialized sender/request lifecycle.** Vidyut reads, encrypts, uploads, and
   waits for a complete receiver acknowledgement for each 1 MiB chunk before
   beginning the next. Raw single-stream TCP is nearly five times faster.
2. **Per-chunk application work.** Every chunk creates Dart lists/copies,
   crosses crypto and HTTP layers, and causes receiver routing, progress, queue
   persistence, open/write/sync/close, and JSON logging.
3. **Excessive control/update frequency.** Odyssey generated 3,552 progress
   events. UI/log updates do not need chunk-level frequency even if durable
   acknowledgements remain precise.
4. **Preparation latency.** Mandatory picker staging is invisible and
   unmeasured; whole-file source hashing then adds roughly 23–26 MiB/s worth of
   pre-offer work.
5. **Final verification latency.** Necessary for integrity, but should be shown
   separately from active transfer.

The isolated laptop disk and crypto tests show that `fsync` and receiver crypto
are contributors to each serialized cycle, not independent 4.5 MiB/s hardware
ceilings. Phone-side per-stage timing is still missing, so the report does not
claim a precise percentage for encryption versus HTTP/list-copy overhead.

## Recommended implementation experiment order

1. Add timestamps/counters for source read, encryption, HTTP send/wait,
   receiver decrypt, write, sync, persistence, and acknowledgement.
2. Keep a bounded receiver writer open and coalesce durable checkpoints.
3. Pipeline two ordered chunks with a strict maximum unconfirmed-byte window.
4. Throttle user-facing progress/control logging to once per second.
5. Compare 1, 2, and 4 MiB chunks after the two-chunk pipeline is stable.
6. Repeat the exact TCP, RFS, and Odyssey matrices; reject changes that weaken
   crash recovery, hash integrity, or latency.

## Commands used

```bash
# Phone server (already bundled on this device)
adb shell 'iperf3 -s -D'

# Laptop → phone
iperf3 -c 192.168.29.154 -P <1|2|4|8> -t 12 -O 2 --json

# Phone → laptop
iperf3 -c 192.168.29.154 -R -P <1|2|4|8> -t 12 -O 2 --json

# UDP sweep
iperf3 -c 192.168.29.154 [-R] -u -b <rate>M -t 8 -O 1 --json

# Link telemetry
iw dev wlp2s0 link
adb shell dumpsys wifi
```

## Limitations

- One phone, laptop, router placement, channel, and time window.
- Public internet speed was intentionally excluded.
- Parallel TCP retransmission counts were variable between runs.
- The phone-side iperf server CPU child process was not captured reliably by
  the Android `top -p` probe.
- Android picker import duration and phone-side per-chunk CPU were not
  instrumented in the release app.
- Re-run at least three full audit windows on different days before treating
  the measured ceiling as a device-wide constant.

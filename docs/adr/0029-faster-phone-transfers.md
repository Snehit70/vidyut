# Phone transfers overlap work and hash while sending

> Status: accepted

Phone file sends were slower than the Wi-Fi for four separate reasons, all
in the phone's loop:

1. Each 1 MB chunk waited for encrypt, disk, and the peer's reply before the
   next chunk started, so the radio sat idle.
2. After every chunk the phone rewrote its whole transfer history and flushed
   the partial file.
3. Ciphertext was built as a boxed `List<int>`, about eight times the memory
   of the raw bytes.
4. Before the first byte went out, the phone read the whole file to checksum
   it. A 2 GB video sat on "preparing" for that whole pass.

Wi-Fi coming back also waited on the 2/4/8/16/32 s reconnect backoff, because
the app did not listen for a usable network.

## What changed

- While one chunk is on the wire, the phone prepares the next. Downloads ask
  for the next range while the current one is decrypted and written. The
  laptop still accepts phone uploads in order.
- History and partial-file checkpoints happen every few megabytes or seconds,
  and always at the end or on failure. Resume still uses the laptop's
  confirmed offset and the partial file's length.
- Chunk crypto uses flat `Uint8List` buffers.
- A laptop that advertises `deferred_file_hash` in `hello` lets the phone skip
  the pre-offer hash. The offer carries the all-zero placeholder digest. The
  phone checksums each chunk as it reads it for upload, and puts the real
  SHA-256 on the last PUT as `x-vidyut-sha256`. The laptop hashes the file it
  received and checks that header. An older laptop never advertises the
  feature, so the phone still hashes before the offer. Staged copies already
  have a digest from the staging pass and keep putting it in the offer.
- Android `ConnectivityManager` fires `vidyut/network_available` when a
  default network is usable again. If the phone is fully offline, it
  reconnects immediately instead of waiting out the backoff. "Searching"
  (socket open, waiting for the laptop) is left alone, because Android also
  reports the current network as soon as something subscribes.

## Consequences

- Sending starts as soon as the phone has size and a live session, when the
  laptop is current.
- An interrupted deferred send re-reads the already-confirmed prefix to
  rebuild the running checksum, then continues.
- Integrity is unchanged: the laptop still hashes what landed on disk.
- Kotlin network callbacks are compile-checked in CI, not in this environment.

# Files use a durable transfer module, not the clipboard pool

The clipboard pool and file sharing have incompatible semantics.

The pool holds exactly one latest payload in memory. It is replayed to late
joiners and overwritten by a newer timestamp. A file transfer instead has a
stable identity, a durable lifecycle, progress, cancellation, retries, partial
state, a destination, and potentially many files in one batch.

Therefore file sharing lives behind a separate transfer module and does not add
`file` to `PayloadType`.

The module's external interface is intentionally small:

```text
enqueue(files) -> batch
observe() -> transfer snapshots
pause/resume/cancel/retry(target)
```

The implementation owns queue persistence, source access, destination access,
encrypted chunk transport, integrity checks, retry policy, notifications, and
history. UI, share intake, file-manager integration, and tests all cross this
same seam.

Control messages use the authenticated WebSocket already connected to the
relay. File bytes use authenticated HTTP requests on the relay's existing port.
The receiver pulls ranges from the sender so it can enforce policy and resume
from confirmed progress. The relay routes streams but never retains completed
file contents.

Rejected:

- **Add files to the clipboard pool.** This would make large files base64 JSON,
  replay them as clipboard state, and erase transfer lifecycle information.
- **Store complete files in the relay.** This creates unnecessary duplication
  and turns the relay into a durable file repository.
- **Open temporary payload ports.** KDE Connect can do this through its link
  abstraction, but one port is simpler for Vidyut's firewall, installation, and
  diagnostics.
- **Push bytes immediately.** Receiver-driven pull gives storage checks,
  acceptance, pausing, and range resume one natural owner.


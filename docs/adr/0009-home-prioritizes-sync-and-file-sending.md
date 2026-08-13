# Home prioritizes automatic sync and explicit file sending

> Status: accepted

The paired Home remains an operational status surface, but it is no longer
buttonless. Its primary hierarchy is automatic clipboard-sync status, an
explicit **Send files** action, and latest activity. Setup status belongs in
Settings because pairing and recovery are infrequent configuration tasks, not
ordinary Home content. This supersedes ADR 0004's persistent Home Setup row
and prohibition on an in-app file action while preserving its status-first
intent. Relay identity is available from connection details or Settings, not
as ordinary Home content. The user-facing **Ready** state requires both a live
phone-to-relay connection and a healthy laptop clipboard watcher; a connected
but degraded clipboard path is presented as needing attention.

## Considered Options

- Keep Home buttonless and rely entirely on notifications or the Android share
  sheet for actions.
- Turn Home into a broad action hub with clipboard, files, settings, and
  diagnostics.

The first hides the important manual file workflow; the second makes a
background utility feel like a launcher. The accepted design keeps one clear
manual action while retaining a calm status-first Home.

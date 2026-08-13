# Paired home is a buttonless status dashboard

> Status: superseded by ADR 0009

Usage is notification-first: once paired, the app is driven from the persistent
notification and the share sheet, and the app itself is opened mainly to answer
"is it working?". So the paired home screen is a **dashboard, not an action
hub**: the status hero (morphing blob + status word) stays the centerpiece, and
below it sit exactly three information rows —

- **Last activity** — the most recent sync event ("text (14 chars) to laptop ·
  2m ago"), persisted so it survives an app restart.
- **Relay identity** — which laptop, `host:port`.
- **Setup health** — a *persistent* row ("All clear" / "2 issues") that opens
  the setup checklist, replacing the petal banner that only appeared when
  something was broken.

There are **no buttons in the paired home body**, and the app bar holds only
Settings. We deliberately rejected:

- **"Reset pairing" as the home CTA (the status quo)** — a destructive,
  once-a-month action styled as the app's primary button, duplicated in the
  app bar, with no confirmation. See ADR 0005 for where it went.
- **An action hub ("Send clipboard" CTA)** — the notification button already
  does this; a home CTA would be theater for a notification-first tool.
- **Debug log in the app bar** — a bug-report icon is not a first-class surface
  in a product meant to be handed to a friend; it moved into Settings.

The accepted trade-off: sending from inside the app takes an extra step if the
notification was swiped away. In exchange the happy-path screen contains
nothing dangerous, and everything on it answers the one question that brings
users there.

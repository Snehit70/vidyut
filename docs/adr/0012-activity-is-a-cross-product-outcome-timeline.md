# Activity is a cross-product outcome timeline

> Status: superseded by [ADR 0017](0017-activity-separates-clipboard-and-file-surfaces.md)

Vidyut's **Activity** surface is a lightweight timeline of meaningful sharing
outcomes across the product. It includes clipboard Payloads, screenshots, and
file Transfer summaries. Files and Transfer history remain the detailed source
of truth for file progress, recovery, and file actions.

Activity records successful outcomes and meaningful failures, but not every
transfer progress tick. A user should be able to answer "what just happened?"
without opening Files or reading the debug log.

Background-originated outcomes, including automatic screenshot and clipboard
publishing, remain durable after the app is backgrounded or closed. When the UI
is visible, new events appear immediately; when it resumes, it reloads the
durable activity state. Relative timestamps advance while the surface remains
open.

## Considered options

- Keep Activity limited to manual clipboard sends and receives.
- Make Transfer history the only file-facing history and leave Activity as a
  payload-only feed.
- Use one cross-product Activity timeline with compact Transfer summaries and
  detailed Transfer state kept in Files.

The first option makes automatic sharing invisible. The second splits the
answer to "what just happened?" across multiple places. The accepted option
keeps the overview unified without duplicating the detailed Transfer model.

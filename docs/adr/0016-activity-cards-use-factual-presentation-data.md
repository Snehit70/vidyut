# Activity cards use factual presentation data

> Status: accepted

Vidyut's Recent activity surface uses a timeline layout with compact cards,
but the cards may show richer recognition data only when that data is present
on the Activity event. The event can provide a display title, detail line,
text excerpt, media metadata, and a preview reference. Older or minimal events
continue to render from their existing summary.

The screen includes a paired-device context row and a chronological timeline
rail. Sent and received direction remain distinct. Received text and image
payloads keep their copy action, while failed events expose a retry affordance
only when the event has an actionable retry callback. Activity remains an
outcome overview; transfer progress, recovery, and file actions remain in
Files and Transfer history.

## Decision

Use optional presentation fields with conservative fallbacks instead of
deriving or inventing filenames, text bodies, dimensions, MIME types, or image
previews from a summary string. This keeps the visual treatment expressive
without making the overview a second source of truth or exposing inaccurate
metadata.

## Consequences

- New producers can progressively add useful display metadata.
- Existing persisted events remain readable and retain their current meaning.
- The UI can match the intended visual hierarchy without requiring every event
  to have a thumbnail or detailed transfer model.
- Retry behavior must be supplied by the owning workflow, not guessed by the
  Activity screen.

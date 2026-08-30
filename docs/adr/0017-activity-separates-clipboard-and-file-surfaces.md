# Activity separates clipboard and file surfaces

> Status: accepted
> Supersedes: [ADR 0012](0012-activity-is-a-cross-product-outcome-timeline.md)

Recent activity is a lightweight chronological surface for clipboard Payloads
and screenshots. It does not include regular file Transfer summaries.

The surface answers what clipboard or screenshot share just happened. Text
Payloads show an excerpt and an explicit `Copy text` action. Clipboard image
Payloads show a preview and `Copy image`. Sent screenshots show presentation
data and `View preview`, but not Copy because they were sent to the laptop
rather than received by the phone. Failed screenshot shares remain visible
inline with a reason and a retry action when supported.

Files and Transfer history remain the source of truth for file progress,
recovery, and file actions. This keeps Recent activity useful for fast
confirmation without duplicating the Transfer model or turning the surface
into a second file manager.

## Considered options

- Keep one cross-product timeline containing clipboard Payloads, screenshots,
  and Transfer summaries.
- Make Recent activity payload-only and move all file Transfer information to
  Files and Transfer history.
- Split clipboard text, clipboard images, and screenshots into separate
  activity surfaces.

The second option preserves one quick answer for clipboard and screenshot
sharing while maintaining a clear boundary around the detailed file workflow.

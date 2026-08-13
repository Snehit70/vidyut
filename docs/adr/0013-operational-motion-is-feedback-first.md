# Operational motion is feedback-first

> Status: accepted

Vidyut uses motion to explain state, acknowledge actions, and preserve spatial
continuity. It does not animate static content for spectacle. Routine app
routes use Material transitions; presses use immediate feedback; connection,
searching, transfer, completion, and theme changes use short state transitions.

Long scrollable surfaces, especially Settings, render their content immediately
and do not use staggered entrance choreography. Searching and progress may loop
only while active. Every nonessential movement respects Android's reduced-motion
setting, replacing spatial movement with instant or short opacity/color
feedback while preserving state clarity.

## Considered options

- Animate every screen and list item to create a more expressive product feel.
- Remove animation entirely for maximum predictability.
- Use bounded, semantic motion for state and feedback while keeping operational
  surfaces instant.

The first option creates latency and animation debt in a utility used during
other work. The second loses useful feedback. The accepted option keeps motion
purposeful and quiet.

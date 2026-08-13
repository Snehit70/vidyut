# Settings use grouped list sections

> Status: accepted

Settings uses one continuous scroll surface with labeled sections and grouped
rows. A section may have one tonal container with internal dividers, but each
setting is not presented as an independent floating Card. Related controls are
kept close; distinct groups receive clear spacing. Long explanations are
shortened in rows and expanded only where the user needs more detail.

The section order is Appearance, Connection, Clipboard & screenshots, Files,
Notifications, Troubleshooting, About, and Danger zone. The master **Sync with
laptop** control and paired-device identity belong to Connection. Detailed
transfer state remains in Files.

Settings data that arrives asynchronously keeps its row and layout stable from
the first frame. It uses an inline loading or unavailable state rather than
delaying or revealing a staggered card later.

## Considered options

- Keep one independent rounded Card per setting.
- Use a dense, ungrouped preference list with only text dividers.
- Use grouped list sections with tonal containers and internal row dividers.

The first option makes adjacent settings visually stick together and gives
every row equal visual weight. The second weakens section identity. The
accepted option keeps scanability and the Vidyut tonal surface language without
the attached-card effect.

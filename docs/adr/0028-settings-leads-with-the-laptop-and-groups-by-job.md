# Settings leads with the laptop and groups rows by job

> Status: accepted. Replaces the section order in ADR 0014 and the separate
> Danger zone from ADR 0006. The grouped-list surface in ADR 0014 stays.

Settings had grown to about seventeen rows in sections ordered by when each
was added. The laptop was a plain row under a switch, the two notification
toggles sat in different sections, and a broken permission was found only
under Troubleshooting.

The order is now:

1. **Setup banner**, shown only while Setup status has open items.
2. **Connection**: paired laptop, the **Sync with laptop** master switch
   (ADR 0006), Laptop folders (ADR 0026), and Forget this laptop last.
3. **Automatic sending**: screenshots, clipboard auto-send, verification
   codes. These are the things the phone sends without being asked.
4. **Receiving files**: receive, destination, size limit, metered Wi-Fi.
5. **Notifications**: both alerts together, worded without "payloads".
6. **Appearance**, as an inline System / Light / Dark choice.
7. **Troubleshooting**, then **About**.

Forget this laptop joins Connection instead of a Danger zone at the bottom, so
the pairing's controls sit next to its identity. It keeps its error colour and
its confirmation dialog. The Xiaomi mention in Setup status appears only on a
Xiaomi phone.

Rejected: keeping Danger zone separate (it put the one pairing action a page
away from the pairing), and a banner that is always present (it would train
people to ignore it).

## Home

Home's **Send files** button is replaced by **Send clipboard or link**. Files
already has its own entry in the app bar (and the navigation rail on wide
screens), so the button was a second way into the same page. Sending the copied
text had no way in from the app itself, only from the notification and the
share sheet. A copied link goes as a link (ADR 0022), so one action covers both.
Home's Send files button is therefore no longer a way to start a file send; the
Files page keeps its own Send files button.

## Files

The Files page is quieter. Rows are plain lines with thin dividers instead of a
bordered card each, and only a selected or failing row is tinted. Each row has
a small arrow for the direction (up for sent, down for received) next to the
words. Search is an icon in the app bar that opens a search field, and the
direction and date filter sits beside it. The Active and Needs attention chips
appear only when something is active or failing. The laptop entry is a full-width
row, "Browse your laptop's folders", instead of a short "Laptop" button. Pictures
sent from the phone now get thumbnails too: they are read through their content
URI (up to 4 MB) and fall back to the type icon when that access is gone.

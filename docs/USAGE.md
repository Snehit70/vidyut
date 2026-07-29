# Using Vidyut Day to Day

Once you've paired (see [`SETUP.md`](SETUP.md)), Vidyut fades into the background.
This is what it's like to actually live with it.

## The mental model

Your laptop and phone share **one clipboard**. There is exactly one item in it at a
time — the **latest** thing you copied on either device. No history, no list to scroll,
no "which one did I want." Copy something new anywhere and it becomes *the* clipboard on
both devices.

- **Same WiFi only.** Both devices must be on the same LAN. Nothing ever goes to the
  internet.
- **Encrypted.** Every payload is end-to-end encrypted with your pairing secret; other
  devices on the WiFi can't read it, and the relay never sees plaintext.
- **Latest wins.** If both devices copy at nearly the same moment, the newer one wins.

---

## Laptop → phone

**You do nothing on the laptop but copy.** The relay watches your clipboard, so any text
or image you `Ctrl+C` (or screenshot to the clipboard) is published automatically.

On the phone:

- **With clipboard permission granted** (from setup), the payload lands in the phone
  clipboard silently — **zero taps**. Open any app and paste. A quiet receipt
  notification also appears.
- **If that grant is missing** (or MIUI blocked the silent write), tap the receipt
  notification — that's the guaranteed fallback and copies the item into the clipboard.

The home screen's **Last activity** card always shows the most recent item ("text (44 B)
from laptop · just now"), so you can confirm it arrived at a glance.

---

## Phone → laptop

Android forbids apps from reading your clipboard in the background, so sending *from* the
phone is a deliberate action — but usually a light one.

### Screenshots — automatic

With **Auto-send screenshots** on (Settings) and full photos access, every screenshot you
take is pushed to the laptop clipboard on its own. Take the shot, switch to the laptop,
`Ctrl+V`. Nothing to tap.

### Anything else — share-sheet push (one tap)

For any image or text, use Android's share sheet:

> **Share → Vidyut**

The item is pushed to the laptop clipboard and you get a success/failure indication. This
is the universal path — it works for a photo, a selected link, a snippet, anything
shareable.

### Text you copied — the notification action

The persistent sync notification carries a **Send copied text** action. Tap it to push
whatever text you last copied on the phone to the laptop. Vidyut reads it through a
brief transparent Android activity, reports the result in the notification, and leaves
you in the app where you copied the text.

### Advanced: zero-tap text auto-send (opt-in)

If you want copied *text* to fly to the laptop with **no tap at all**, there's an
opt-in mode under **Settings → Advanced** that needs a one-time `adb` grant on the
computer (`READ_LOGS`). It's off by default and per-phone; a normal install never needs
it. Screenshots and share-sheet push already cover the zero-/one-tap story without it.

---

## The home screen

The paired home is a **buttonless status dashboard** — there's nothing to press, it just
tells you the truth:

- **Connected / status ring** — whether the phone and laptop currently share a clipboard.
- **Last activity** — the most recent payload, its type/size, direction, and when.
- **Relay** — the laptop's address you're paired to.
- **Setup** — "All clear," or a tap-through to fix whatever's degraded.

Everything else lives behind the **gear icon → Settings**.

## Settings at a glance

- **Auto-send screenshots** — the screenshot auto-push toggle.
- **Notify when laptop payloads arrive** — receipt notifications on/off (delivery-failure
  notices always show).
- **Setup status** — the live permission/OEM checklist; your recovery surface when
  something stops working.
- **Advanced** — the opt-in READ_LOGS text auto-send (one-time computer setup).
- **Debug log** — timestamped connection and payload events, newest first. This is where
  you look first when sync misbehaves (Flutter logs don't reach `logcat`).
- **Forget this laptop** (Danger zone) — deletes the pairing and stops syncing. Use it to
  move to a new laptop or revoke a device, then re-pair from scratch.

---

## When something's off

- **Is the relay fine?** One curl from the laptop answers it:
  `curl http://localhost:17321/health` — uptime, which devices are connected
  (the phone should be listed), and the age of the current pool payload.
- **Nothing syncing?** Check both devices are on the same WiFi, and the home screen says
  Connected. Sync resumes on its own when WiFi drops and returns (the phone reconnects
  with backoff).
- **Screenshot arrived but won't paste on the laptop?** Install ImageMagick — MIUI
  screenshots arrive as JPEG and most Linux apps only paste PNG.
- **Phone got killed by MIUI?** Re-check **Setup status** — Autostart, "No restrictions"
  battery, and Lock-in-recents are the usual culprits.

Field-verified symptom → cause → fix entries live in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
# File sharing

On Android, open **Files** in Vidyut and tap **Send files**, or share one or
more files to Vidyut from another app. Received files appear in
`Downloads/Vidyut` by default; change the folder under **Settings → Files**.

On Linux, select files in Dolphin or Nautilus and choose **Send with Vidyut**,
or click the Vidyut tray icon. From a terminal:

```bash
vidyut-relay --send "/path/to/file"
vidyut-relay --transfers
```

Files are transferred only over the paired LAN connection. Interrupted
transfers retain receiver-confirmed progress and complete files are verified
with SHA-256 before they become visible.

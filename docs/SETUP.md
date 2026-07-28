# Setup Guide (New Users)

Vidyut gives your **Linux/Wayland laptop** and your **Android phone** one shared
clipboard on the same WiFi. Copy a screenshot or some text on one device, paste it on
the other a second later. Everything is end-to-end encrypted and never leaves your LAN.

This guide takes you from nothing to a working laptop ↔ phone paste. Budget ~5 minutes
the first time; pairing is once per phone, then it just runs.

> Already installed and just want to know how to use it? See [`USAGE.md`](USAGE.md).

---

## What you need

- A laptop on a **Wayland** session (X11 and headless are not supported).
- An Android phone on the **same WiFi** as the laptop.
- Both devices able to see each other on the LAN (mDSN/UDP 5353 not blocked).

---

## Part A — Laptop: install the relay

The **relay** is a single compiled binary that watches your laptop clipboard and serves
your paired phone. It runs as a `systemd --user` service that starts with your desktop.

### 1. Install the dependencies

```bash
sudo dnf install wl-clipboard ImageMagick      # Fedora
sudo apt install wl-clipboard imagemagick      # Debian/Ubuntu
```

- **wl-clipboard 2.3+** (`wl-copy`/`wl-paste`) is required — the relay reads and
  writes the clipboard through it. Version 2.3 added the standardized
  `ext-data-control-v1` protocol used by KDE/KWin. Some distributions still
  package 2.2.1; check with `wl-paste --version` and install 2.3+ manually from
  the [upstream release](https://github.com/bugaevc/wl-clipboard/releases/tag/v2.3.0)
  when needed. Vidyut does not replace the distribution package automatically.
- **ImageMagick** (`magick`) is recommended — phone screenshots often arrive as JPEG,
  and most Linux apps only paste `image/png`. The relay re-encodes to PNG when
  ImageMagick is present. Without it, screenshots may land on the clipboard but refuse
  to paste (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)).
- **[Bun](https://bun.sh)** is needed only to *build* the binary, not to run it.

### 2. Build, install, and start

From the repo root:

```bash
bun run install:relay
```

This compiles `dist/vidyut-relay`, installs it to `~/.local/bin/`, installs the
systemd user unit, and starts the service. It is tied to `graphical-session.target`, so
it comes up with your desktop and stops when you log out.

### 3. Get your pairing details

On first start the relay creates `~/.config/vidyut/relay.json` (mode 600) with a
persistent pairing secret, then prints a QR code and a manual fallback line to the
journal:

```bash
journalctl --user -u vidyut-relay -b --no-pager | tail -40
```

You'll see a QR code and a line like:

```text
host=192.168.29.98 port=17321 secret=<pairing-secret>
```

Keep this terminal handy for Part B. The secret never changes between restarts — you
pair once.

> More laptop detail (managing the service, mDNS/firewall notes, port conflicts) lives
> in [`INSTALL.md`](INSTALL.md).

---

## Part B — Phone: install and pair the app

### 1. Install the APK

There is no Play Store build. Get the APK one of two ways:

- **Download the signed ARM64 release APK** from the latest
  [GitHub Release](https://github.com/Snehit70/vidyut/releases/latest). The
  adjacent `.sha256` file can be used to verify the download.

> **Upgrading from 1.1.2:** the old release used a signing key that is no
> longer available, so Android cannot update it in place. Uninstall Vidyut
> 1.1.2 before installing the current release. Uninstalling removes the saved
> pairing and app data, so pair the phone with the laptop again afterward.
> Releases after this migration use a pinned signing identity and update in
> place.

- **Build a development APK** (needs
  [Flutter](https://docs.flutter.dev/get-started/install) `3.44.4`+ stable and
  the Android SDK — see `app/README.md` for dev setup):

  ```bash
  cd app && flutter build apk --debug
  # output: app/build/app/outputs/flutter-apk/app-debug.apk
  ```

Install a development build over USB with `adb`, or copy the downloaded release
APK to the phone and tap it:

```bash
adb install -r app/build/app/outputs/flutter-apk/app-debug.apk
```

### 2. Run the first-run wizard

Open Vidyut. A one-time wizard walks you through the permissions in order and ends at
pairing. Grant everything it asks for — each grant removes a rough edge:

| Grant | Why it matters |
|-------|----------------|
| **Notifications** | Delivery receipts and the persistent sync notification can show. |
| **Photos access (full)** | Screenshots can send themselves. |
| **Battery exemption** | The app stays connected while the phone sleeps. |
| **Clipboard permission** | Received text lands **without a tap** (zero-tap receive). |

On **Xiaomi / MIUI / HyperOS** phones there are extra switches the app can't toggle for
you — the wizard (and the Setup status screen) list them with a shortcut button:

- **Autostart** — let Vidyut restart itself after MIUI kills it.
- **Battery: No restrictions** — pick "No restrictions" on the battery-saver page.
- **Lock in recents** — keep the app from being swiped away by task cleanup.
- **Clipboard permission** — allow clipboard access via the permission editor.

You can revisit all of this any time at **Settings → Setup status**, which shows the
**live** state of every item and how to fix whatever is degraded.

### 3. Pair with the laptop

On the pairing screen, pick whichever is easiest:

- **Auto-discover (recommended):** the app browses for `_vidyut._tcp` on the LAN and
  lists nearby relays. Tap yours — host and port fill in automatically, so you only type
  the secret.
- **Scan the QR** shown in the laptop journal.
- **Manual entry:** type the `host=… port=… secret=…` values yourself.

Once paired, the home screen shows **Connected** and the pairing is saved — you won't
pair again on this WiFi.

---

## Part C — Confirm it works

A 30-second two-way smoke test:

1. **Laptop → phone:** copy some text on the laptop (`Ctrl+C`). Within a second the
   phone's home screen shows it under **Last activity**, and the text is on the phone
   clipboard ready to paste.
2. **Phone → laptop:** take a screenshot on the phone. It auto-sends; on the laptop,
   `wl-paste --list-types` shows `image/png` and `Ctrl+V` pastes the screenshot.

If both work, you're done. For how this fits into everyday use, read
[`USAGE.md`](USAGE.md). If something's off, [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
has the field-verified fixes.

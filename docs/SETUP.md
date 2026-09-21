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

## Part A — Laptop: install the Relay

The **Relay** watches your laptop clipboard and serves your paired phone. It
runs as a `systemd --user` service that starts with your desktop. The desktop
shell is the window for pairing, Ready / Sync needs attention, Files, laptop
setup status, and rotate pairing secret.

### 1. Install the package

Get the `.rpm` or `.deb` from the latest
[GitHub Release](https://github.com/Snehit70/vidyut/releases/latest):

```bash
sudo dnf install ./vidyut-*.rpm      # Fedora
sudo apt install ./vidyut_*.deb      # Debian/Ubuntu
```

The package depends on **wl-clipboard** and **ImageMagick**. It does not need
Bun. After install, open the Vidyut desktop shell. If you are already logged
in, you may need:

```bash
systemctl --user daemon-reload
systemctl --user start vidyut-relay
```

A later version is another GitHub `.rpm` or `.deb` installed with `dnf` or
`apt`. There is no in-app updater.

From source instead, install `wl-clipboard` 2.3+ and ImageMagick, then from
the repo root run `bun run install:relay`. Bun is only for that build.
`wl-paste --version` must report 2.3+ on KDE/KWin. Some distributions still
ship 2.2.1; install 2.3+ from the
[upstream release](https://github.com/bugaevc/wl-clipboard/releases/tag/v2.3.0)
when needed. Details are in [`INSTALL.md`](INSTALL.md).

### 2. Pair from the desktop shell

Open **Vidyut**. The pairing QR, host, port, and secret are on that page.
Point the phone at the QR. One secret is shared by every device.

On first start the Relay writes `~/.config/vidyut/relay.json` (mode 600). It
also prints the QR and a manual line to the journal, which is the fallback:

```bash
journalctl --user -u vidyut-relay -b --no-pager | tail -40
```

```text
host=192.168.29.98 port=17321 secret=<pairing-secret>
```

You pair once. Rotate pairing secret in the desktop shell if you need to
revoke every phone.

> More laptop detail (service commands, mDNS/firewall, port conflicts) lives
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
- **Scan the QR** in the Vidyut desktop shell (journalctl is the fallback).
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

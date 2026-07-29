# Installing The Relay (Laptop)

The relay is a single compiled binary that runs on the Linux/Wayland laptop, watches the clipboard, and serves paired phones over the LAN. This guide installs it as a persistent `systemd --user` service.

## Prerequisites

- A **Wayland session** — the relay reads and writes the clipboard through `wl-copy`/`wl-paste`, so it does not work on X11 or headless machines.
- **wl-clipboard 2.3+** — provides `wl-copy` and `wl-paste`. Version 2.3 added
  `ext-data-control-v1`, which is required for clipboard watching on KDE/KWin:

  ```bash
  sudo dnf install wl-clipboard      # Fedora
  sudo apt install wl-clipboard      # Debian/Ubuntu
  wl-paste --version                 # must report 2.3+ for KDE/KWin
  ```

  Some distribution repositories still contain 2.2.1. If so, install 2.3+
  manually from the
  [upstream wl-clipboard release](https://github.com/bugaevc/wl-clipboard/releases/tag/v2.3.0).
  Vidyut does not download, build, or replace this system dependency.

- **Bun** (build only) — the binary is compiled from source with [Bun](https://bun.sh). Once installed, the service does not need Bun.

## Quick Install

From the repo root:

```bash
bun run install:relay
```

This builds `dist/vidyut-relay`, installs it to `~/.local/bin/vidyut-relay`, installs the unit from `packaging/systemd/vidyut-relay.service` to `~/.config/systemd/user/`, and enables + starts the service.

It also installs the Vidyut file picker/tray, a Dolphin **Send with Vidyut**
service menu, and a Nautilus **Send with Vidyut** script. The tray uses `yad`
and the picker uses `zenity`; file-manager actions work independently of the
tray.

The unit is tied to `graphical-session.target`, so the relay starts with your desktop session and stops when you log out.

## Pairing

On first start the relay creates `~/.config/vidyut/relay.json` (mode 600) with a persistent pairing secret, then prints a QR code and a manual fallback line:

```text
host=<lan-ip> port=17321 secret=<pairing-secret>
```

When running under systemd that output lands in the journal. To pair the phone:

```bash
journalctl --user -u vidyut-relay -b --no-pager | tail -40
```

Scan the QR code with the Vidyut app, or use the app's manual entry with the `host=... port=... secret=...` line. If the QR renders poorly in your terminal, widen the window or use manual entry — the secret never changes between restarts, so pairing once is enough.

Alternatively, pair before installing the service by running the binary directly once: `./dist/vidyut-relay`.

## Managing The Service

```bash
systemctl --user status vidyut-relay    # is it running?
journalctl --user -u vidyut-relay -f    # follow logs
systemctl --user restart vidyut-relay   # restart (e.g. after rebuilding)
systemctl --user disable --now vidyut-relay   # stop and disable
```

After pulling changes, re-run `bun run install:relay` to rebuild, reinstall, and restart in one step (re-enabling an enabled service is a no-op).

## Troubleshooting

- **`wl-copy` errors / clipboard not syncing**: the service can't see your Wayland display. GNOME and KDE import `WAYLAND_DISPLAY` into the systemd user environment automatically; on other compositors (e.g. sway) run `systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP` from your session startup, then restart the service.
- **KDE/KWin reports degraded clipboard health**: check
  `curl -sS http://127.0.0.1:17321/health` and
  `journalctl --user -u vidyut-relay -b -o cat | grep clipboard_watch`.
  `wl-clipboard` 2.2.1 cannot watch KWin's standardized data-control protocol;
  install 2.3+ manually, then restart the relay.
- **Port already in use**: the relay refuses to start if its port (default `17321`) is taken. Change `port` in `~/.config/vidyut/relay.json` and restart.
- **Phone can't discover the relay**: the relay advertises `_vidyut._tcp` over mDNS. Make sure the laptop firewall allows mDNS (UDP 5353) and the relay port on your LAN zone, and that both devices are on the same network.

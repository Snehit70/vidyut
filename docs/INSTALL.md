# Installing the Relay (laptop)

The Relay is a compiled binary that runs on the Linux/Wayland laptop, watches
the clipboard, and serves paired phones on the LAN. It is a `systemd --user`
unit. The desktop shell is a window and tray around that Relay. Closing the
window does not stop the Pool.

Bun is a build tool. Installed packages do not need it.

## Packages from GitHub Releases

The laptop install is a `.rpm` or `.deb` from
[GitHub Releases](https://github.com/Snehit70/vidyut/releases). The package
depends on `wl-clipboard` and ImageMagick, installs `vidyut-relay`, the
desktop shell, the systemd user unit, a desktop file, and Send with Vidyut
for Dolphin and Nautilus.

```bash
sudo dnf install ./vidyut-*.rpm      # Fedora
sudo apt install ./vidyut_*.deb      # Debian/Ubuntu
```

Then log in to a Wayland session, or start the unit in the current session:

```bash
systemctl --user daemon-reload
systemctl --user start vidyut-relay
```

Open the Vidyut desktop shell. The pairing QR, host, port, and secret are on
that page. `journalctl --user -u vidyut-relay` still prints the QR if you need
a fallback.

A newer GitHub release is another `.rpm` or `.deb` installed with `dnf` or
`apt`. The desktop shell does not download or overwrite binaries. Open
releases on that page is a GitHub link, nothing more.

## Prerequisites

- A **Wayland session**. The Relay reads and writes the clipboard through
  `wl-copy`/`wl-paste`. X11 and headless are not supported.
- **wl-clipboard 2.3+** for `wl-copy` and `wl-paste`. 2.3 added
  `ext-data-control-v1`, which KDE/KWin needs:

  ```bash
  sudo dnf install wl-clipboard      # Fedora
  sudo apt install wl-clipboard      # Debian/Ubuntu
  wl-paste --version                 # must report 2.3+ for KDE/KWin
  ```

  Some distribution repositories still contain 2.2.1. If so, install 2.3+
  from the
  [upstream wl-clipboard release](https://github.com/bugaevc/wl-clipboard/releases/tag/v2.3.0).
  Vidyut does not download, build, or replace this system dependency.

- **ImageMagick** (`magick`). Phone screenshots often arrive as JPEG, and most
  Linux apps only paste PNG. The package depends on it.
- **Bun** only if you build from source. The installed binary does not need it.
- **Desktop shell from source** needs WebKitGTK 4.1. Fedora packages for a
  local `bun run build:shell`:

  ```bash
  sudo dnf install gtk3-devel webkit2gtk4.1-devel openssl-devel \
    libappindicator-gtk3-devel librsvg2-devel gcc
  ```

  `yad` is not required.

## Build packages from this tree

```bash
bun run build:relay
bun run build:shell
bash scripts/build-linux-packages.sh
```

That writes `.rpm` and `.deb` under `dist/packages/` using `nfpm.yaml`.
`nFPM` must be on `PATH`. See https://nfpm.goreleaser.com/docs/install/.

## Install from the repo (no package)

From the repo root:

```bash
bun run install:relay
```

This builds `dist/vidyut-relay`, installs it to `~/.local/bin/vidyut-relay`,
installs the unit from `packaging/systemd/vidyut-relay.service` to
`~/.config/systemd/user/`, and enables + starts the service.

It also installs Dolphin **Send with Vidyut** and a Nautilus **Send with
Vidyut** script. If `src-tauri/target/release/vidyut-shell` (or debug) exists,
the installer copies that desktop shell to `~/.local/bin/vidyut-shell` and
adds an autostart `.desktop` for it. Closing the window or tray Quit leaves
the Relay running. File-manager actions work without the shell.

Build the shell first with `bun run build:shell` when you want the window and
tray. `vidyut-send` with no files opens the shell if it is installed.

The unit is tied to `graphical-session.target`, so the Relay starts with your
desktop session and stops when you log out.

## Pairing

Open the Vidyut desktop shell and point the phone at the pairing QR. Host,
port, and secret are on the same page. One secret is shared by every device.

On first start the Relay creates `~/.config/vidyut/relay.json` (mode 600)
with a persistent pairing secret. It also prints a QR and a manual line to
the journal, which is the fallback when the shell is not open:

```text
host=<lan-ip> port=17321 secret=<pairing-secret>
```

```bash
journalctl --user -u vidyut-relay -b --no-pager | tail -40
```

Scan the QR with the Vidyut app, or use manual entry with the
`host=... port=... secret=...` line. Laptop revocation is rotate pairing
secret in the desktop shell, not Forget this laptop.

You can also pair once by running the binary directly: `./dist/vidyut-relay`.

## Managing the service

```bash
systemctl --user status vidyut-relay    # is it running?
journalctl --user -u vidyut-relay -f    # follow logs
systemctl --user restart vidyut-relay   # restart (e.g. after rebuilding)
systemctl --user disable --now vidyut-relay   # stop and disable
```

After pulling source changes, re-run `bun run install:relay` to rebuild,
reinstall, and restart. Packaged installs take a newer `.rpm` or `.deb`
instead.

## Troubleshooting

- **`wl-copy` errors / clipboard not syncing**: the service can't see your
  Wayland display. GNOME and KDE import `WAYLAND_DISPLAY` into the systemd
  user environment automatically. On other compositors (e.g. sway) run
  `systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP`
  from your session startup, then restart the service.
- **KDE/KWin reports degraded clipboard health**: check
  `curl -sS http://127.0.0.1:17321/health` and
  `journalctl --user -u vidyut-relay -b -o cat | grep clipboard_watch`.
  `wl-clipboard` 2.2.1 cannot watch KWin's standardized data-control protocol.
  Install 2.3+ manually, then restart the Relay.
- **Port already in use**: the Relay refuses to start if its port (default
  `17321`) is taken. Change `port` in `~/.config/vidyut/relay.json` and
  restart.
- **Phone can't discover the Relay**: the Relay advertises `_vidyut._tcp`
  over mDNS. Allow mDNS (UDP 5353) and the Relay port on your LAN zone, and
  keep both devices on the same network.

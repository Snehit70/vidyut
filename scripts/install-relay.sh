#!/usr/bin/env bash
# Build the relay binary and install it as a systemd --user service.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
unit_dir="${HOME}/.config/systemd/user"
applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
kde_services_dir="${XDG_DATA_HOME:-$HOME/.local/share}/kio/servicemenus"
nautilus_scripts_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus/scripts"

for tool in wl-copy wl-paste; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: $tool not found. Install wl-clipboard first (Fedora: sudo dnf install wl-clipboard)." >&2
    exit 1
  fi
done

for tool in notify-send python3; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: $tool is required by the Linux file-sharing integrations." >&2
    exit 1
  fi
done

if ! command -v bun >/dev/null; then
  echo "error: bun not found. Install Bun to build the relay: https://bun.sh" >&2
  exit 1
fi

echo "Building relay binary..."
(cd "$repo_root" && bun install --frozen-lockfile && bun run build:relay)

mkdir -p "$bin_dir" "$unit_dir" "$applications_dir" "$autostart_dir" \
  "$kde_services_dir" "$nautilus_scripts_dir"
install -m 755 "$repo_root/dist/vidyut-relay" "$bin_dir/vidyut-relay"
install -m 755 "$repo_root/scripts/vidyut-send" "$bin_dir/vidyut-send"
install -m 755 "$repo_root/scripts/vidyut-transfer-history" "$bin_dir/vidyut-transfer-history"
install -m 644 "$repo_root/packaging/systemd/vidyut-relay.service" "$unit_dir/vidyut-relay.service"
sed "s|@VIDYUT_BIN_DIR@|$bin_dir|g" \
  "$repo_root/packaging/desktop/vidyut-send.desktop" \
  >"$applications_dir/vidyut-send.desktop"
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi
sed "s|@VIDYUT_BIN_DIR@|$bin_dir|g" \
  "$repo_root/packaging/kde/vidyut-send.desktop" \
  >"$kde_services_dir/vidyut-send.desktop"
chmod 755 "$kde_services_dir/vidyut-send.desktop"
install -m 755 "$repo_root/packaging/nautilus/Send with Vidyut" "$nautilus_scripts_dir/Send with Vidyut"

icon_hicolor="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
install -D -m 644 "$repo_root/src-tauri/icons/32x32.png" "$icon_hicolor/32x32/apps/vidyut.png"
install -D -m 644 "$repo_root/src-tauri/icons/128x128.png" "$icon_hicolor/128x128/apps/vidyut.png"
install -D -m 644 "$repo_root/src-tauri/icons/128x128@2x.png" "$icon_hicolor/256x256/apps/vidyut.png"
install -D -m 644 "$repo_root/src-tauri/icons/icon.png" "$icon_hicolor/512x512/apps/vidyut.png"
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -f "$icon_hicolor" >/dev/null 2>&1 || true
fi

rm -f "$bin_dir/vidyut-tray" "$autostart_dir/vidyut-tray.desktop"

shell_bin=""
for candidate in \
  "$repo_root/src-tauri/target/release/vidyut-shell" \
  "$repo_root/src-tauri/target/debug/vidyut-shell"
do
  if [[ -x "$candidate" ]]; then
    shell_bin="$candidate"
    break
  fi
done

if [[ -n "$shell_bin" ]]; then
  install -m 755 "$shell_bin" "$bin_dir/vidyut-shell"
  sed "s|@VIDYUT_BIN_DIR@|$bin_dir|g" \
    "$repo_root/packaging/desktop/vidyut.desktop" \
    >"$applications_dir/vidyut.desktop"
  sed "s|@VIDYUT_BIN_DIR@|$bin_dir|g" \
    "$repo_root/packaging/desktop/vidyut.desktop" \
    >"$autostart_dir/vidyut.desktop"
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
  fi
else
  rm -f "$autostart_dir/vidyut.desktop"
  echo "warning: vidyut-shell is not built. Run bun run build:shell, then re-run this installer for the desktop shell." >&2
fi

systemctl --user daemon-reload
# `enable --now` only starts the unit when it is not already running, so on
# every install after the first it left the previous binary serving. Restart
# explicitly so the binary just installed is the one actually running.
systemctl --user enable vidyut-relay.service
systemctl --user restart vidyut-relay.service

# Confirm the unit came up, so a failed install is not reported as a success.
for _ in $(seq 1 25); do
  if systemctl --user is-active --quiet vidyut-relay.service; then
    break
  fi
  sleep 0.2
done
if ! systemctl --user is-active --quiet vidyut-relay.service; then
  echo "error: vidyut-relay.service did not come up. Check: journalctl --user -u vidyut-relay -b --no-pager | tail -40" >&2
  exit 1
fi

echo
echo "Installed and started vidyut-relay.service."
echo "Pairing QR: open the Vidyut desktop shell."
echo "Fallback:   journalctl --user -u vidyut-relay -b --no-pager | tail -40"
echo "Follow logs:  journalctl --user -u vidyut-relay -f"

#!/usr/bin/env bash
# Stage Relay + desktop shell files and build .rpm / .deb with nFPM.
# Does not need Bun at packaging time. The package does not depend on Bun.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

stub_shell=0
for arg in "$@"; do
  case "$arg" in
    --stub-shell) stub_shell=1 ;;
    -h|--help)
      echo "Usage: $0 [--stub-shell]"
      echo "Requires dist/vidyut-relay and src-tauri/target/release/vidyut-shell,"
      echo "plus nfpm on PATH. --stub-shell is for CI layout checks only."
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v nfpm >/dev/null; then
  echo "error: nfpm not found. Install nFPM from https://nfpm.goreleaser.com/docs/install/" >&2
  exit 1
fi

version="$(python3 -c 'import json, pathlib; print(json.loads(pathlib.Path("package.json").read_text())["version"])')"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: package.json version is not X.Y.Z: $version" >&2
  exit 1
fi
export VIDYUT_VERSION="$version"

relay_bin="$repo_root/dist/vidyut-relay"
if [[ ! -x "$relay_bin" ]]; then
  echo "error: $relay_bin is missing. Run bun run build:relay first." >&2
  exit 1
fi

stage="$repo_root/dist/linux-pkg"
rm -rf "$stage"
mkdir -p "$stage"

shell_bin="${VIDYUT_SHELL_BIN:-$repo_root/src-tauri/target/release/vidyut-shell}"
if [[ ! -x "$shell_bin" ]]; then
  if [[ "$stub_shell" -eq 1 ]]; then
    shell_bin="$stage/vidyut-shell.stub"
    printf '%s\n' '#!/bin/sh' 'echo "vidyut-shell stub; build the desktop shell for a real package"' 'exit 0' >"$shell_bin"
    chmod 755 "$shell_bin"
  else
    echo "error: vidyut-shell is missing. Run bun run build:shell, or pass --stub-shell." >&2
    exit 1
  fi
fi

install -m 755 "$relay_bin" "$stage/vidyut-relay"
install -m 755 "$shell_bin" "$stage/vidyut-shell"
install -m 755 "$repo_root/scripts/vidyut-send" "$stage/vidyut-send"
install -m 755 "$repo_root/scripts/vidyut-transfer-history" "$stage/vidyut-transfer-history"

sed 's|@VIDYUT_BIN_DIR@|/usr/bin|g' \
  "$repo_root/packaging/desktop/vidyut.desktop" >"$stage/vidyut.desktop"
sed 's|@VIDYUT_BIN_DIR@|/usr/bin|g' \
  "$repo_root/packaging/desktop/vidyut-send.desktop" >"$stage/vidyut-send.desktop"
sed 's|@VIDYUT_BIN_DIR@|/usr/bin|g' \
  "$repo_root/packaging/kde/vidyut-send.desktop" >"$stage/kde-vidyut-send.desktop"

python3 - "$repo_root/packaging/nautilus/Send with Vidyut" "$stage/Send with Vidyut" <<'PY'
from pathlib import Path
import sys
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text()
text = text.replace(
    'sender="${XDG_BIN_HOME:-$HOME/.local/bin}/vidyut-send"',
    'sender="/usr/bin/vidyut-send"',
)
dst.write_text(text)
dst.chmod(0o755)
PY

out="$repo_root/dist/packages"
rm -rf "$out"
mkdir -p "$out"

nfpm package --config nfpm.yaml --packager rpm --target "$out"
nfpm package --config nfpm.yaml --packager deb --target "$out"

echo
echo "Built Linux packages for $VIDYUT_VERSION:"
ls -l "$out"

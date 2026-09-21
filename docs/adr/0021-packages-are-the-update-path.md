# Distro packages are the update path

> Status: accepted

Linux updates are a newer `.rpm` or `.deb` from GitHub Releases, installed
with the system package manager. The desktop shell may notice a newer release
and open the GitHub page. It does not download or overwrite binaries.

A Tauri in-app updater was rejected because the Relay is installed as a
packaged systemd user unit. Overwriting those files from the shell fights
dnf/apt. A user-space `~/.local` bundle that Tauri can patch would throw away
the package install. Signing and repo hosting stay later work.

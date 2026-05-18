#!/usr/bin/env bash
# Bind-mount /mnt/ccache to $HOME/ccache-mirror. Idempotent.
# The kernel-build workflow uses CCACHE_DIR=/mnt/ccache/.ccache when /mnt/ccache
# exists and is writable; otherwise it falls back to $HOME/.ccache.
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SRC="${USER_HOME}/ccache-mirror"
DST="/mnt/ccache"
FSTAB_LINE="${SRC} ${DST} none bind,nofail 0 0"
FSTAB_TAG="# kernel-build ccache bind-mount"

sudo mkdir -p "$DST"
mkdir -p "$SRC" "$SRC/.ccache" "$SRC/.ccache/tmp"
sudo chown "$USER_NAME":"$USER_NAME" "$DST"

if ! grep -F "$FSTAB_LINE" /etc/fstab >/dev/null 2>&1; then
  printf '\n%s\n%s\n' "$FSTAB_TAG" "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  echo "Appended fstab entry."
else
  echo "fstab entry already present."
fi

if mountpoint -q "$DST"; then
  echo "$DST already mounted."
else
  sudo mount "$DST"
  echo "Mounted $DST."
fi

# Initial ccache config so the first run primes correctly.
if command -v ccache >/dev/null 2>&1; then
  CCACHE_DIR="${DST}/.ccache" ccache -M 50G >/dev/null 2>&1 || true
  echo "ccache max size set to 50G under ${DST}/.ccache"
fi

ls -la "$DST"
mount | grep -F "$DST" || true

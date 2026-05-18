#!/usr/bin/env bash
# Set up a bind-mount so /mnt/Hawai/toolchains points at $HOME/toolchains.
# Idempotent: safe to re-run.
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SRC="${USER_HOME}/toolchains"
DST="/mnt/Hawai/toolchains"
FSTAB_LINE="${SRC} ${DST} none bind,nofail 0 0"
FSTAB_TAG="# kernel-build toolchains bind-mount"

# Ensure source and target exist with sane perms
sudo mkdir -p "$DST"
mkdir -p "$SRC"
sudo chown "$USER_NAME":"$USER_NAME" "$DST"

# Append fstab entry only if absent
if ! grep -F "$FSTAB_LINE" /etc/fstab >/dev/null 2>&1; then
  printf '\n%s\n%s\n' "$FSTAB_TAG" "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  echo "Appended fstab entry."
else
  echo "fstab entry already present."
fi

# Mount now (skip if already mounted)
if mountpoint -q "$DST"; then
  echo "$DST already mounted."
else
  sudo mount "$DST"
  echo "Mounted $DST."
fi

# Hint readme
cat > "$SRC/README.md" <<'EOF'
# Self-hosted runner toolchains

This directory is bind-mounted to /mnt/Hawai/toolchains.
The kernel-build workflow probes:
  /mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin/clang
  /mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
  /mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-
If they are not present, the workflow falls back to PATH toolchains.

To populate, drop the prebuilts here and they will be visible at the paths above.
EOF

ls -la "$DST" || true
mount | grep -F "$DST" || true

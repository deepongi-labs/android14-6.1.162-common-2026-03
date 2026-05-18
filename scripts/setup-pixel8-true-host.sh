#!/usr/bin/env bash
# One-time host setup for a real Pixel 8 (shusky/zuma) Kleaf+Bazel kernel build
# on the WSL Arch self-hosted runner. Idempotent; safe to re-run.
set -euo pipefail

REPO_BIN=/usr/local/bin/repo

echo "[setup] Installing system packages"
sudo pacman -S --noconfirm --needed \
  base-devel git curl tar bc cpio rsync ccache \
  python python-pip python-yaml python-pyelftools \
  jdk17-openjdk \
  bison flex unzip zip kmod dtc \
  git-lfs \
  libxcrypt-compat icu jq

if [ ! -x "$REPO_BIN" ]; then
  echo "[setup] Installing 'repo'"
  sudo curl -fL https://storage.googleapis.com/git-repo-downloads/repo -o "$REPO_BIN"
  sudo chmod +x "$REPO_BIN"
else
  echo "[setup] 'repo' already installed at $REPO_BIN"
fi

# Java is needed for Bazel; pick OpenJDK 17 if multiple versions are available.
if command -v archlinux-java >/dev/null 2>&1; then
  default_java="$(archlinux-java get || true)"
  if [ "$default_java" != "java-17-openjdk" ] && archlinux-java status 2>/dev/null | grep -q java-17-openjdk; then
    sudo archlinux-java set java-17-openjdk
  fi
fi

# Make sure the workflow's bind-mounted scratch dirs exist.
for d in /mnt/Android/source-mirrors /mnt/ccache/.ccache /mnt/Android/akita; do
  sudo mkdir -p "$d"
  sudo chown "$USER":"$USER" "$d"
done

# Pre-create the akita tree root the workflow uses by default, so the runner
# has a stable, large path on the ext4 disk rather than 9p-backed /mnt/c.
mkdir -p "$HOME/pixel8-akita"

# git-lfs hooks (Kleaf occasionally pulls LFS-backed prebuilts)
git lfs install --skip-repo >/dev/null 2>&1 || true

# Configure git for repo (a name/email is required by `repo init`).
git config --global user.email >/dev/null 2>&1 || git config --global user.email "runner@pixel8-wsl.local"
git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "Pixel8 WSL Runner"
git config --global color.ui false
git config --global advice.detachedHead false

echo "[setup] Toolchain check (Bazel uses Kleaf-vendored clang, not these):"
clang --version | head -1 || true
java -version 2>&1 | head -1 || true
"$REPO_BIN" --version 2>&1 | head -3 || true

echo "[setup] Done."

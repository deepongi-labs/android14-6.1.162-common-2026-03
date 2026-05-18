#!/usr/bin/env bash
# Sync a Pixel 8-series device kernel manifest tree using `repo`.
# Default device target is akita (Pixel 8a). For Pixel 8 / 8 Pro pass
# the shusky branch as the third argument.
#
# Usage:
#   sync-pixel8-true-kernel.sh <root_dir> <manifest_url> <manifest_branch>
#
# Examples:
#   sync-pixel8-true-kernel.sh "$HOME/pixel8-akita"  \\
#       https://android.googlesource.com/kernel/manifest \\
#       android-gs-akita-6.1-android15-qpr2
#
#   sync-pixel8-true-kernel.sh "$HOME/pixel8-shusky" \\
#       https://android.googlesource.com/kernel/manifest \\
#       android-gs-shusky-6.1-android15-qpr2
#
# Idempotent. Re-running just refreshes refs.
set -euo pipefail

ROOT="${1:?root_dir required}"
MANIFEST_URL="${2:-https://android.googlesource.com/kernel/manifest}"
MANIFEST_BRANCH="${3:-android-gs-akita-6.1-android15-qpr2}"

REPO_BIN="${REPO_BIN:-/usr/local/bin/repo}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$ROOT"
cd "$ROOT"

echo "[sync] root            = $ROOT"
echo "[sync] manifest url    = $MANIFEST_URL"
echo "[sync] manifest branch = $MANIFEST_BRANCH"
echo "[sync] jobs            = $JOBS"

if [ ! -d .repo ]; then
  echo "[sync] repo init"
  "$REPO_BIN" init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 --no-clone-bundle --partial-clone --clone-filter=blob:limit=10M
else
  echo "[sync] repo init (refresh)"
  "$REPO_BIN" init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 --no-clone-bundle --partial-clone --clone-filter=blob:limit=10M
fi

echo "[sync] repo sync"
"$REPO_BIN" sync -c -j"$JOBS" --no-tags --no-clone-bundle --force-sync --optimized-fetch

echo "[sync] manifest snapshot:"
"$REPO_BIN" manifest -r -o "$ROOT/.repo/manifests-snapshot.xml"
ls -la "$ROOT/.repo/manifests-snapshot.xml"

echo "[sync] tree summary:"
ls -la "$ROOT" | head -20
echo "[sync] tools/bazel: $(ls -la "$ROOT/tools/bazel" 2>/dev/null || echo 'MISSING')"
echo "[sync] aosp/Makefile: $(ls -la "$ROOT/aosp/Makefile" 2>/dev/null || echo 'MISSING')"

case "$MANIFEST_BRANCH" in
  *akita*)  device_dir="private/devices/google/akita"  ;;
  *shusky*) device_dir="private/devices/google/shusky" ;;
  *)        device_dir=""                              ;;
esac
if [ -n "$device_dir" ]; then
  echo "[sync] $device_dir/BUILD.bazel: $(ls -la "$ROOT/$device_dir/BUILD.bazel" 2>/dev/null || echo 'MISSING')"
fi

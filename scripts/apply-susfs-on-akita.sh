#!/usr/bin/env bash
# Apply the existing SuSFS + KSU enhancement patch series against the
# akita/shusky manifest tree. The common kernel lives at <ROOT>/aosp/ so
# we run patch -p1 from inside that directory.
#
# Usage:
#   apply-susfs-on-akita.sh <root_dir> <variant> <patches_dir> [strict|best_effort]
#
# variant: tiann | kowsu | resukisu | next | enhance
# patches_dir: path to .github/patches in this workflow repo
set -euo pipefail

ROOT="${1:?root_dir required}"
VARIANT="${2:?variant required}"
PATCHES_DIR="${3:?patches_dir required}"
POLICY="${4:-best_effort}"

KERNEL_DIR="$ROOT/aosp"
[ -d "$KERNEL_DIR" ] || { echo "[patch] aosp/ not found"; exit 2; }

# Locate or fetch susfs4ksu so we can copy headers + fs sources into the tree.
# Priority: $SUSFS_SRC env var → sibling susfs4ksu/ dir → clone from upstream.
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android14-6.1-dev}"
if [ -z "${SUSFS_SRC:-}" ]; then
  if [ -d "$ROOT/susfs4ksu/kernel_patches" ]; then
    SUSFS_SRC="$ROOT/susfs4ksu"
  elif [ -d "$(dirname "$0")/../susfs4ksu/kernel_patches" ]; then
    SUSFS_SRC="$(realpath "$(dirname "$0")/../susfs4ksu")"
  else
    echo "[patch] susfs4ksu not found locally; cloning branch $SUSFS_BRANCH"
    git clone --depth=1 -b "$SUSFS_BRANCH" \
      https://gitlab.com/simonpunk/susfs4ksu.git "$ROOT/susfs4ksu-fetch"
    SUSFS_SRC="$ROOT/susfs4ksu-fetch"
  fi
fi
echo "[patch] susfs4ksu source: $SUSFS_SRC"
cp -v "$SUSFS_SRC/kernel_patches/fs/susfs.c"                  "$KERNEL_DIR/fs/"
cp -v "$SUSFS_SRC/kernel_patches/include/linux/susfs.h"       "$KERNEL_DIR/include/linux/"
cp -v "$SUSFS_SRC/kernel_patches/include/linux/susfs_def.h"   "$KERNEL_DIR/include/linux/"

mkdir -p "$ROOT/logs"
manifest="$ROOT/logs/patch-manifest-$VARIANT.txt"
failure_log="$ROOT/logs/patch-failure-$VARIANT.log"
: > "$manifest"
: > "$failure_log"

apply() {
  local patch="$1"
  local label="$2"
  local optional="${3:-false}"

  if [ ! -f "$patch" ]; then
    if [ "$optional" = "true" ]; then
      echo "[patch] skip (not present): $label  ($patch)" | tee -a "$manifest"
      return 0
    fi
    echo "[patch] MISSING required: $label  ($patch)" | tee -a "$failure_log"
    [ "$POLICY" = "strict" ] && exit 4
    return 0
  fi

  if (cd "$KERNEL_DIR" && patch -p1 --dry-run --silent < "$patch") >/dev/null 2>&1; then
    (cd "$KERNEL_DIR" && patch -p1 < "$patch") >/dev/null
    echo "[patch] applied: $label" | tee -a "$manifest"
  else
    echo "[patch] FAILED dry-run: $label" | tee -a "$failure_log"
    (cd "$KERNEL_DIR" && patch -p1 --dry-run < "$patch") >> "$failure_log" 2>&1 || true
    if [ "$POLICY" = "strict" ]; then
      echo "[patch] strict mode -> abort"
      exit 5
    fi
  fi
}

# Drift-fix patches FIRST: these add upstream-divergent #include lines so
# the SuSFS 50-patch hunk anchors line up against akita's aosp/ tree.
for p in "$PATCHES_DIR/global"/*.patch; do
  [ -f "$p" ] || continue
  apply "$p" "global/$(basename "$p")" true
done

# SuSFS-in-GKI patch (reuses naming from the GKI workflow patch sets).
apply "$PATCHES_DIR/$VARIANT/50_add_susfs_in_gki-android14-6.1.patch" "$VARIANT/50_add_susfs_in_gki" false
apply "$PATCHES_DIR/$VARIANT/10_enable_susfs_for_ksu.patch"          "$VARIANT/10_enable_susfs_for_ksu" true
apply "$PATCHES_DIR/$VARIANT/20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch" "$VARIANT/20_spoof_lkm" true
apply "$PATCHES_DIR/$VARIANT/30-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch" "$VARIANT/30_spoof_lkm" true

echo "[patch] manifest -> $manifest"
echo "[patch] failures -> $failure_log"

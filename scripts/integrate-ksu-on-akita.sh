#!/usr/bin/env bash
# Integrate a KernelSU variant into the akita (or shusky) manifest tree.
# The common kernel sits at <ROOT>/aosp/, so KSU drops under
# <ROOT>/aosp/drivers/kernelsu and Kbuild/Kconfig pick it up.
#
# Usage:
#   integrate-ksu-on-akita.sh <root_dir> <variant> <ksu_repo_url> <ksu_ref>
#
# variant: tiann | kowsu | resukisu | next | enhance
#
# Re-running is safe: drivers/kernelsu is removed first.
set -euo pipefail

ROOT="${1:?root_dir required}"
VARIANT="${2:?variant required}"
KSU_REPO="${3:?ksu_repo_url required}"
KSU_REF="${4:?ksu_ref required}"

KERNEL_DIR="$ROOT/aosp"
[ -d "$KERNEL_DIR" ] || { echo "[ksu] aosp/ not found at $KERNEL_DIR; did sync run?" >&2; exit 2; }

cd "$ROOT"

echo "[ksu] cleanup any previous KSU residue"
rm -rf KernelSU
rm -rf "$KERNEL_DIR/drivers/kernelsu"
# undo any prior Makefile/Kconfig appends so we stay idempotent
sed -i '/obj-\$(CONFIG_KSU) += kernelsu\//d' "$KERNEL_DIR/drivers/Makefile" 2>/dev/null || true
sed -i '\|source "drivers/kernelsu/Kconfig"|d' "$KERNEL_DIR/drivers/Kconfig" 2>/dev/null || true

echo "[ksu] cloning $VARIANT ($KSU_REPO @ $KSU_REF)"
git clone --depth=1 "$KSU_REPO" KernelSU
( cd KernelSU && (git fetch --depth=1 origin "$KSU_REF" || git fetch --depth=1 origin "+refs/heads/$KSU_REF:refs/remotes/origin/$KSU_REF" || true) && git checkout --detach "FETCH_HEAD" 2>/dev/null || git checkout "$KSU_REF" )

[ -d KernelSU/kernel ] || { echo "[ksu] KernelSU/kernel missing after checkout"; ls -la KernelSU; exit 3; }

mkdir -p "$KERNEL_DIR/drivers"
ln -sfn "$ROOT/KernelSU/kernel" "$KERNEL_DIR/drivers/kernelsu"

# Wire Kbuild + Kconfig if not already present
grep -q '^obj-\$(CONFIG_KSU)' "$KERNEL_DIR/drivers/Makefile" || \
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

# Persist for downstream steps
echo "$VARIANT"  > "$ROOT/.ksu-variant"
echo "$KSU_REPO" > "$ROOT/.ksu-repo"
( cd KernelSU && git rev-parse HEAD ) > "$ROOT/.ksu-sha"

echo "[ksu] integrated $VARIANT @ $(cat "$ROOT/.ksu-sha")"
ls -l "$KERNEL_DIR/drivers/kernelsu" || true
tail -2 "$KERNEL_DIR/drivers/Makefile"
grep -n 'kernelsu' "$KERNEL_DIR/drivers/Kconfig" || true

#!/usr/bin/env bash
# Build True Pixel 8a Enhance Kernel (Device-Specific, Not GKI)
#
# This script builds a device-specific kernel for Pixel 8a (akita)
# with KernelSU (enhance variant), SuSFS, and kerneltoast Tensor G3 patches.
# Unlike the GKI build, this includes all device-specific drivers, configs,
# and device trees required for Pixel 8a to boot.
#
# Requirements:
#   - repo tool installed (/usr/local/bin/repo or in PATH)
#   - 50GB+ free disk space
#   - Build dependencies: git, curl, build-essential, bc, bison, flex, libssl-dev, libelf-dev
#
# Usage:
#   ./build-pixel8-enhance-akita.sh [device] [android_version]
#
# Examples:
#   ./build-pixel8-enhance-akita.sh akita android16
#
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE="${1:-akita}"
ANDROID_VERSION="${2:-android16}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/pixel8-enhance-build}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KernelSU variant for enhance - use pinned ref for SuSFS patch compatibility
KSU_VARIANT="enhance"
KSU_REPO="https://github.com/tiann/KernelSU"
KSU_REF="da8e0ab1786dc55cce3ed4ff4c304be614e0fa0a"

# SuSFS
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android14-6.1-dev"

# Kerneltoast Tensor G3 scheduler/power patches
KERNELTOAST_PATCH_POLICY="${KERNELTOAST_PATCH_POLICY:-best_effort}"
KT_PATCH_ARCH_TOPOLOGY_MIN_FREQ_SCALE_URL="https://github.com/kerneltoast/android_kernel_google_tensynos/commit/48a3fd5e41.patch"
KT_PATCH_SCHED_CASS_UCLAMP_PACKING_URL="https://github.com/kerneltoast/android_kernel_google_tensynos/commit/201c5c7c99.patch"
KT_PATCH_SCHEDUTIL_IGNORE_FIE_RATELIMIT_URL="https://github.com/kerneltoast/android_kernel_google_tensynos/commit/56040db35c.patch"
KT_PATCH_SCHEDUTIL_DEFAULT_RATELIMIT_URL="https://github.com/kerneltoast/android_kernel_google_tensynos/commit/627184a51c.patch"

# Manifest selection
case "$DEVICE" in
  akita)
    MANIFEST_BRANCH="android-gs-akita-6.1-${ANDROID_VERSION}-beta"
    DEVICE_TARGET="akita"
    ;;
  shiba|husky|shusky)
    MANIFEST_BRANCH="android-gs-shusky-6.1-${ANDROID_VERSION}-beta"
    DEVICE_TARGET="shusky"
    ;;
  *)
    echo "❌ Unknown device: $DEVICE"
    echo "   Supported: akita (Pixel 8a), shiba (Pixel 8), husky (Pixel 8 Pro)"
    exit 1
    ;;
esac

MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
BUILD_ROOT="$WORKSPACE_ROOT/$DEVICE-$ANDROID_VERSION"
KERNEL_DIR="$BUILD_ROOT/aosp"
OUTPUT_DIR="$SCRIPT_DIR/out-pixel8-$DEVICE"

echo "=========================================="
echo "Pixel 8 Enhance Kernel Builder"
echo "=========================================="
echo "Device:          $DEVICE"
echo "Android:         $ANDROID_VERSION"
echo "Manifest:        $MANIFEST_BRANCH"
echo "Build root:      $BUILD_ROOT"
echo "Output:          $OUTPUT_DIR"
echo "=========================================="
echo ""

# ============================================================================
# STEP 1: CHECK DEPENDENCIES
# ============================================================================

echo "## Step 1: Checking dependencies..."

if ! command -v repo >/dev/null 2>&1; then
  echo "❌ repo tool not found"
  echo "   Install: curl https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && chmod +x /usr/local/bin/repo"
  exit 1
fi

REQUIRED_TOOLS="git curl bc bison flex make gcc"
MISSING_TOOLS=""
for tool in $REQUIRED_TOOLS; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS="$MISSING_TOOLS $tool"
  fi
done

if [ -n "$MISSING_TOOLS" ]; then
  echo "❌ Missing tools:$MISSING_TOOLS"
  echo "   Install: sudo pacman -S base-devel bc bison flex"
  exit 1
fi

echo "✅ All dependencies found"
echo ""

# ============================================================================
# STEP 2: SYNC PIXEL 8 KERNEL TREE
# ============================================================================

echo "## Step 2: Syncing Pixel 8 kernel tree..."

mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

if [ ! -d .repo ]; then
  echo "   Initializing repo..."
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" \
    --depth=1 --no-clone-bundle --partial-clone --clone-filter=blob:limit=10M
else
  echo "   Refreshing repo..."
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" \
    --depth=1 --no-clone-bundle --partial-clone --clone-filter=blob:limit=10M
fi

echo "   Syncing sources (this may take 10-30 minutes)..."
repo sync -c -j"$(nproc)" --no-tags --no-clone-bundle --force-sync --optimized-fetch

if [ ! -d "$KERNEL_DIR" ]; then
  echo "❌ Kernel directory not found: $KERNEL_DIR"
  echo "   The manifest sync may have failed"
  exit 1
fi

echo "✅ Kernel tree synced"
repo manifest -r -o "$BUILD_ROOT/.repo/manifest-snapshot.xml"
echo ""

# ============================================================================
# STEP 3: INTEGRATE KERNELSU
# ============================================================================

echo "## Step 3: Integrating KernelSU ($KSU_VARIANT)..."

cd "$BUILD_ROOT"

# Clean previous KSU
rm -rf KernelSU
rm -rf "$KERNEL_DIR/drivers/kernelsu"
sed -i '/obj-\$(CONFIG_KSU) += kernelsu\//d' "$KERNEL_DIR/drivers/Makefile" 2>/dev/null || true
sed -i '\|source "drivers/kernelsu/Kconfig"|d' "$KERNEL_DIR/drivers/Kconfig" 2>/dev/null || true

# Clone KernelSU (supports both branch names and commit SHAs)
echo "   Cloning $KSU_REPO @ $KSU_REF..."
if git ls-remote --heads "$KSU_REPO" "$KSU_REF" | grep -q "$KSU_REF"; then
  git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" KernelSU
else
  git clone "$KSU_REPO" KernelSU
  git -C KernelSU fetch origin "$KSU_REF"
  git -C KernelSU checkout "$KSU_REF"
  git -C KernelSU checkout --detach
fi

if [ ! -d KernelSU/kernel ]; then
  echo "❌ KernelSU/kernel directory not found"
  exit 1
fi

# Symlink into kernel tree
mkdir -p "$KERNEL_DIR/drivers"
ln -sfn "$BUILD_ROOT/KernelSU/kernel" "$KERNEL_DIR/drivers/kernelsu"

# Wire Kbuild + Kconfig
echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$KERNEL_DIR/drivers/Makefile"
sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

KSU_SHA=$(cd KernelSU && git rev-parse HEAD)
echo "✅ KernelSU integrated @ $KSU_SHA"
echo ""

# ============================================================================
# STEP 4: INTEGRATE SUSFS
# ============================================================================

echo "## Step 4: Integrating SuSFS..."

cd "$BUILD_ROOT"

if [ ! -d susfs4ksu ]; then
  echo "   Cloning $SUSFS_REPO @ $SUSFS_BRANCH..."
  git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
fi

if [ ! -d susfs4ksu/kernel_patches ]; then
  echo "❌ SuSFS kernel_patches not found"
  exit 1
fi

# Copy SuSFS sources
echo "   Copying SuSFS sources..."
cp -v susfs4ksu/kernel_patches/fs/susfs.c "$KERNEL_DIR/fs/"
cp -v susfs4ksu/kernel_patches/include/linux/susfs.h "$KERNEL_DIR/include/linux/"
cp -v susfs4ksu/kernel_patches/include/linux/susfs_def.h "$KERNEL_DIR/include/linux/"

# Apply patches
echo "   Applying SuSFS patches..."
PATCHES_DIR="$SCRIPT_DIR/.github/patches"

if [ ! -d "$PATCHES_DIR" ]; then
  echo "⚠️  Patches directory not found: $PATCHES_DIR"
  echo "   Skipping patch application"
else
  # Apply global patches to kernel tree
  for patch in "$PATCHES_DIR/global"/*.patch; do
    [ -f "$patch" ] || continue
    echo "   Applying global $(basename "$patch")..."
    (cd "$KERNEL_DIR" && patch -p1 --forward < "$patch") || echo "   (already applied or failed)"
  done

  # Apply variant-specific patches to kernel tree (core kernel patches - fs/, mm/, kernel/, security/)
  VARIANT_PATCHES="$PATCHES_DIR/$KSU_VARIANT"
  if [ -d "$VARIANT_PATCHES" ]; then
    for patch in "$VARIANT_PATCHES"/*.patch; do
      [ -f "$patch" ] || continue
      pname=$(basename "$patch")

      # Check if patch targets KernelSU-internal files (kernel/Kbuild, kernel/Kconfig, kernel/core/, etc.)
      # These need to be applied inside the KernelSU source tree, not the main kernel tree
      if head -50 "$patch" | grep -qE '^[+-]{3}.*kernel/(Kbuild|Kconfig|Makefile|core/|feature/|hook/|include/|policy/|runtime/|selinux/|sulog/|supercall/)'; then
        echo "   Applying $(basename "$patch") (to KernelSU source)..."
        (cd "$BUILD_ROOT/KernelSU/kernel" && patch -p1 --forward < "$patch") || echo "   (already applied or failed)"
      else
        echo "   Applying $(basename "$patch") (to kernel tree)..."
        (cd "$KERNEL_DIR" && patch -p1 --forward < "$patch") || echo "   (already applied or failed)"
      fi
    done
  fi
fi

echo "✅ SuSFS integrated"
echo ""

# ============================================================================
# STEP 5: APPLY KERNELTOAST SCHEDULER/POWER PATCHES (Tensor G3 Optimizations)
# ============================================================================

echo "## Step 5: Applying kerneltoast scheduler/power patches..."

if [ "${KERNELTOAST_PATCH_POLICY}" != "off" ]; then
  cd "$KERNEL_DIR"
  export PATCH_MANIFEST="${PATCH_MANIFEST:-/dev/null}"
  
  apply_remote_patch_with_policy() {
    local url="$1"
    local local_name="$2"
    local description="$3"
    local destination="/tmp/${local_name}"
    if ! curl --fail --location --silent --show-error "$url" -o "$destination"; then
      if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
        echo "❌ ${description} download failed in strict mode: ${url}"
        exit 1
      fi
      echo "⚠️  Skipping ${description}: failed to download ${url}"
      return 0
    fi
    if [ ! -s "$destination" ]; then
      if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
        echo "❌ ${description} downloaded empty patch in strict mode: ${url}"
        exit 1
      fi
      echo "⚠️  Skipping ${description}: downloaded empty patch"
      return 0
    fi
    if patch -p1 --forward --dry-run < "$destination" >/dev/null 2>&1; then
      patch -p1 --forward < "$destination"
      echo "✅ Applied ${description}"
    elif patch -p1 --reverse --dry-run < "$destination" >/dev/null 2>&1; then
      echo "ℹ️ ${description} already present, skipping"
    else
      if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
        echo "❌ ${description} failed to apply"
        exit 1
      fi
      echo "⚠️  Skipping ${description}: patch rejected"
    fi
  }
  
  processed=0
  
  apply_remote_patch_with_policy "${KT_PATCH_ARCH_TOPOLOGY_MIN_FREQ_SCALE_URL}" "kt-arch-topology-min-freq-scale.patch" "kerneltoast: arch_topology minimum frequency scale"
  processed=$((processed + 1))
  
  if [ -f kernel/sched/cass.c ]; then
    python3 - <<'PY'
from pathlib import Path
path = Path('kernel/sched/cass.c')
text = path.read_text()
if 'arch_scale_min_freq_capacity(cpu)' in text:
    raise SystemExit(0)
old = '''\t\t\t/*
\t\t\t * A non-idle candidate may be better for energy
\t\t\t * efficiency when @p is uclamp boosted, or when the
\t\t\t * only idle candidate found so far is the prime CPU.
\t\t\t * Otherwise, prefer idle candidates.
\t\t\t */
\t\t\tif (!uc_min && !cass_prime_cpu(curr)) {
\t\t\t\t/* Discard any previous non-idle candidate */
\t\t\t\tif (!has_idle)
\t\t\t\t\tbest = curr;
\t\t\t\thas_idle = true;
\t\t\t}'''
new = '''\t\t\t/*
\t\t\t * A non-idle candidate may be better for energy
\t\t\t * efficiency when @p is uclamp boosted above @curr's
\t\t\t * minimum capacity, or when the only idle candidate
\t\t\t * found so far is the prime CPU. Otherwise, prefer idle
\t\t\t * candidates.
\t\t\t */
\t\t\tif (!has_idle &&
\t\t\t    uc_min <= arch_scale_min_freq_capacity(cpu) &&
\t\t\t    !cass_prime_cpu(curr)) {
\t\t\t\t/* Discard any previous non-idle candidate */
\t\t\t\tbest = curr;
\t\t\t\thas_idle = true;
\t\t\t}'''
if old in text:
    text = text.replace(old, new)
    path.write_text(text)
    print("✅ kerneltoast: sched/cass uclamp packing threshold applied")
else:
    print("⚠️  kerneltoast: CASS uclamp packing context not found for direct edit")
PY
  else
    echo "ℹ️ kerneltoast: sched/cass uclamp packing threshold not applicable; kernel/sched/cass.c is absent"
  fi
  processed=$((processed + 1))
  
  apply_remote_patch_with_policy "${KT_PATCH_SCHEDUTIL_IGNORE_FIE_RATELIMIT_URL}" "kt-schedutil-ignore-fie-rate-limit.patch" "kerneltoast: schedutil ignore FIE rate-limit on scale-up"
  processed=$((processed + 1))
  
  apply_remote_patch_with_policy "${KT_PATCH_SCHEDUTIL_DEFAULT_RATELIMIT_URL}" "kt-schedutil-default-rate-limit.patch" "kerneltoast: schedutil default rate-limit 2000us"
  processed=$((processed + 1))
  
  echo "✅ Kerneltoast patchset: ${processed} patches processed"
  cd "$BUILD_ROOT"
else
  echo "⚠️  kerneltoast patchset disabled by policy"
fi

echo ""

# ============================================================================
# STEP 6: CONFIGURE KERNEL

echo "## Step 6: Configuring kernel..."

cd "$KERNEL_DIR"

# Generate base config
echo "   Generating gki_defconfig..."
make ARCH=arm64 LLVM=1 O=out gki_defconfig

# Apply KernelSU + SuSFS configs
echo "   Applying KernelSU/SuSFS configs..."
cat >> out/.config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_MODULES=y
CONFIG_MODULE_SIG=y
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_MODVERSIONS=y
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_IOSCHED_BFQ=y
CONFIG_BFQ_GROUP_IOSCHED=y
# CONFIG_WERROR is not set
EOF

# Run olddefconfig to resolve dependencies
make ARCH=arm64 LLVM=1 O=out olddefconfig

echo "✅ Kernel configured"
echo ""

# ============================================================================
# STEP 7: BUILD KERNEL

echo "## Step 7: Building kernel..."

cd "$KERNEL_DIR"

MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
echo "   Building with $MAKE_JOBS parallel jobs..."

make -j"$MAKE_JOBS" \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  LD=ld.lld \
  HOSTLD=ld.lld \
  O=out \
  CC="ccache clang" \
  KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-error=uninitialized-const-reference" \
  all

if [ ! -f out/arch/arm64/boot/Image ]; then
  echo "❌ Kernel build failed - Image not found"
  exit 1
fi

echo "✅ Kernel built successfully"
echo ""

# ============================================================================
# STEP 8: PACKAGE OUTPUT

echo "## Step 8: Packaging output..."

mkdir -p "$OUTPUT_DIR"

# Copy kernel Image
cp -v out/arch/arm64/boot/Image "$OUTPUT_DIR/"

# Generate Image.lz4
if command -v lz4 >/dev/null 2>&1; then
  echo "   Compressing kernel with lz4..."
  lz4 -9 -f out/arch/arm64/boot/Image "$OUTPUT_DIR/Image.lz4"
else
  echo "⚠️  lz4 not found, skipping compression"
fi

# Copy config
cp -v out/.config "$OUTPUT_DIR/config"

# Generate build info
cat > "$OUTPUT_DIR/build-info.txt" <<EOF
Device: $DEVICE
Android: $ANDROID_VERSION
Manifest: $MANIFEST_BRANCH
KernelSU: $KSU_SHA
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Kernel Version: $(cat out/include/config/kernel.release 2>/dev/null || echo "unknown")
EOF

echo "✅ Output packaged to: $OUTPUT_DIR"
echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "=========================================="
echo "✅ BUILD COMPLETE"
echo "=========================================="
echo "Kernel Image:  $OUTPUT_DIR/Image"
if [ -f "$OUTPUT_DIR/Image.lz4" ]; then
  echo "Kernel LZ4:    $OUTPUT_DIR/Image.lz4"
fi
echo "Config:        $OUTPUT_DIR/config"
echo "Build Info:    $OUTPUT_DIR/build-info.txt"
echo ""
echo "Next steps:"
echo "  1. Repack boot image:"
echo "     export KERNEL_IMAGE=\"$OUTPUT_DIR/Image\""
echo "     ./repack-akita-android16.sh"
echo ""
echo "  2. Flash to device:"
echo "     fastboot boot boot-akita-android16-*.img"
echo ""
echo "  3. Permanent flash (after successful test):"
echo "     fastboot --disable-verity --disable-verification flash vbmeta_a"
echo "     fastboot --disable-verity --disable-verification flash vbmeta_b"
echo "     fastboot flash boot_a boot-akita-android16-*.img"
echo "     fastboot flash boot_b boot-akita-android16-*.img"
echo "     fastboot reboot"
echo ""
echo "  4. Verify:"
echo "     adb shell uname -a"
echo "     adb shell dmesg | grep -E 'kernelsu|susfs'"
echo "=========================================="

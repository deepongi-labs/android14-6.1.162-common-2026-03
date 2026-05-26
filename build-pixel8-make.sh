#!/usr/bin/env bash
# Build Device-Specific Pixel 8 Kernel with Make (Not Bazel)
#
# This script syncs the full Pixel 8 manifest tree and builds with make/LLVM
# using your local compilation environment instead of Bazel/Kleaf.
#
# Requirements:
#   - repo tool installed
#   - 50GB+ free disk space
#   - Build dependencies: git, curl, build-essential, bc, bison, flex, libssl-dev, libelf-dev
#
# Usage:
#   ./build-pixel8-make.sh [device] [android_version]
#
# Examples:
#   ./build-pixel8-make.sh akita android16
#   ./build-pixel8-make.sh shusky android16
#
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE="${1:-akita}"
ANDROID_VERSION="${2:-android16}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/pixel8-make-build}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KernelSU variant
KSU_VARIANT="${KSU_VARIANT:-tiann}"
KSU_REPO="https://github.com/tiann/KernelSU"
KSU_REF="${KSU_REF:-main}"

# SuSFS
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android14-6.1-dev}"

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
OUTPUT_DIR="$SCRIPT_DIR/out-pixel8-make-$DEVICE"

# Build configuration
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
USE_CCACHE="${USE_CCACHE:-true}"
LTO_MODE="${LTO_MODE:-thin}"

echo "=========================================="
echo "Pixel 8 Make-Based Kernel Builder"
echo "=========================================="
echo "Device:          $DEVICE"
echo "Android:         $ANDROID_VERSION"
echo "Manifest:        $MANIFEST_BRANCH"
echo "Build root:      $BUILD_ROOT"
echo "Kernel dir:      $KERNEL_DIR"
echo "Output:          $OUTPUT_DIR"
echo "Make jobs:       $MAKE_JOBS"
echo "Use ccache:      $USE_CCACHE"
echo "LTO mode:        $LTO_MODE"
echo "=========================================="
echo ""

# ============================================================================
# STEP 1: CHECK DEPENDENCIES
# ============================================================================

echo "## Step 1: Checking dependencies..."

if ! command -v repo >/dev/null 2>&1; then
  echo "❌ repo tool not found"
  echo "   Install: sudo curl https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo && sudo chmod +x /usr/local/bin/repo"
  exit 1
fi

REQUIRED_TOOLS="git curl bc bison flex make gcc clang lz4"
MISSING_TOOLS=""
for tool in $REQUIRED_TOOLS; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS="$MISSING_TOOLS $tool"
  fi
done

if [ -n "$MISSING_TOOLS" ]; then
  echo "❌ Missing tools:$MISSING_TOOLS"
  echo "   Install: sudo pacman -S base-devel bc bison flex clang lz4"
  exit 1
fi

echo "✅ All dependencies found"
echo ""

# ============================================================================
# STEP 2: SYNC PIXEL 8 KERNEL TREE
# ============================================================================

echo "## Step 2: Syncing Pixel 8 kernel tree..."
echo "   This will download ~10-20GB and take 30-60 minutes"
echo ""

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

echo "   Syncing sources..."
repo sync -c -j"$MAKE_JOBS" --no-tags --no-clone-bundle --force-sync --optimized-fetch

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

# Clone KernelSU
echo "   Cloning $KSU_REPO @ $KSU_REF..."
git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" KernelSU

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

if [ -d "$PATCHES_DIR" ]; then
  # Apply global patches
  for patch in "$PATCHES_DIR/global"/*.patch; do
    [ -f "$patch" ] || continue
    echo "   Applying $(basename "$patch")..."
    (cd "$KERNEL_DIR" && patch -p1 --forward < "$patch") 2>/dev/null || echo "   (already applied or failed)"
  done

  # Apply variant-specific patches
  VARIANT_PATCHES="$PATCHES_DIR/$KSU_VARIANT"
  if [ -d "$VARIANT_PATCHES" ]; then
    for patch in "$VARIANT_PATCHES"/*.patch; do
      [ -f "$patch" ] || continue
      echo "   Applying $(basename "$patch")..."
      (cd "$KERNEL_DIR" && patch -p1 --forward < "$patch") 2>/dev/null || echo "   (already applied or failed)"
    done
  fi
else
  echo "⚠️  Patches directory not found: $PATCHES_DIR"
fi

echo "✅ SuSFS integrated"
echo ""

# ============================================================================
# STEP 5: CONFIGURE KERNEL FOR DEVICE-SPECIFIC BUILD
# ============================================================================

echo "## Step 5: Configuring kernel for device-specific build..."

cd "$KERNEL_DIR"

# Generate base GKI config
echo "   Generating gki_defconfig..."
make ARCH=arm64 LLVM=1 O=out gki_defconfig

# Look for device-specific config fragments
DEVICE_CONFIG_DIR="$BUILD_ROOT/private/devices/google/$DEVICE_TARGET"
if [ -d "$DEVICE_CONFIG_DIR" ]; then
  echo "   Found device config directory: $DEVICE_CONFIG_DIR"
  
  # Merge device-specific fragments if they exist
  for fragment in "$DEVICE_CONFIG_DIR"/*.fragment "$DEVICE_CONFIG_DIR"/*.config; do
    if [ -f "$fragment" ]; then
      echo "   Merging $(basename "$fragment")..."
      cat "$fragment" >> out/.config
    fi
  done
fi

# Apply KernelSU + SuSFS + Performance configs
echo "   Applying KernelSU/SuSFS/Performance configs..."
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
EOF

# Apply LTO configuration
case "$LTO_MODE" in
  thin)
    echo "CONFIG_LTO_CLANG_THIN=y" >> out/.config
    echo "# CONFIG_LTO_CLANG_FULL is not set" >> out/.config
    ;;
  full)
    echo "CONFIG_LTO_CLANG_FULL=y" >> out/.config
    echo "# CONFIG_LTO_CLANG_THIN is not set" >> out/.config
    ;;
  none)
    echo "# CONFIG_LTO_CLANG_THIN is not set" >> out/.config
    echo "# CONFIG_LTO_CLANG_FULL is not set" >> out/.config
    ;;
esac

# Run olddefconfig to resolve dependencies
make ARCH=arm64 LLVM=1 O=out olddefconfig

echo "✅ Kernel configured"
echo ""

# ============================================================================
# STEP 6: BUILD KERNEL WITH MAKE
# ============================================================================

echo "## Step 6: Building kernel with make (not Bazel)..."

cd "$KERNEL_DIR"

# Setup ccache if enabled
if [ "$USE_CCACHE" = "true" ] && command -v ccache >/dev/null 2>&1; then
  export CC="ccache clang"
  echo "   Using ccache for faster builds"
else
  export CC="clang"
fi

echo "   Building with $MAKE_JOBS parallel jobs..."
echo "   This will take 20-60 minutes depending on your CPU..."
echo ""

make -j"$MAKE_JOBS" \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  LD=ld.lld \
  HOSTLD=ld.lld \
  O=out \
  all

if [ ! -f out/arch/arm64/boot/Image ]; then
  echo "❌ Kernel build failed - Image not found"
  exit 1
fi

echo "✅ Kernel built successfully"
echo ""

# ============================================================================
# STEP 7: PACKAGE OUTPUT
# ============================================================================

echo "## Step 7: Packaging output..."

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
KERNEL_VERSION=$(cat out/include/config/kernel.release 2>/dev/null || echo "unknown")
cat > "$OUTPUT_DIR/build-info.txt" <<EOF
Build Method: Make (not Bazel)
Device: $DEVICE
Android: $ANDROID_VERSION
Manifest: $MANIFEST_BRANCH
KernelSU: $KSU_SHA
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Kernel Version: $KERNEL_VERSION
LTO Mode: $LTO_MODE
Make Jobs: $MAKE_JOBS
EOF

echo "✅ Output packaged to: $OUTPUT_DIR"
echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "=========================================="
echo "✅ BUILD COMPLETE"
echo "=========================================="
echo "Build Method:  Make (not Bazel)"
echo "Kernel Image:  $OUTPUT_DIR/Image"
if [ -f "$OUTPUT_DIR/Image.lz4" ]; then
  echo "Kernel LZ4:    $OUTPUT_DIR/Image.lz4"
fi
echo "Config:        $OUTPUT_DIR/config"
echo "Build Info:    $OUTPUT_DIR/build-info.txt"
echo "Kernel Ver:    $KERNEL_VERSION"
echo ""
echo "Next steps:"
echo "  1. Repack boot image:"
echo "     export KERNEL_IMAGE=\"$OUTPUT_DIR/Image\""
echo "     export KERNEL_IMAGE_LZ4=\"$OUTPUT_DIR/Image.lz4\""
echo "     ./repack-simple.sh"
echo ""
echo "  2. Test on device:"
echo "     fastboot boot boot-akita-*.img"
echo ""
echo "  3. Flash permanently (if test succeeds):"
echo "     fastboot flash boot boot-akita-*.img"
echo "     fastboot reboot"
echo "=========================================="

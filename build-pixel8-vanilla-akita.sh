#!/usr/bin/env bash
# Build Vanilla Pixel 8 Kernel (Device-Specific, No KernelSU/SuSFS)
#
# This script builds a clean device-specific kernel for Pixel 8 series (akita/shiba/husky)
# WITHOUT KernelSU or SuSFS. This is a vanilla kernel build with device-specific drivers,
# configs, and device trees required for Pixel 8 to boot.
#
# Requirements:
#   - repo tool installed (/usr/local/bin/repo or in PATH)
#   - 50GB+ free disk space
#   - Build dependencies: git, curl, build-essential, bc, bison, flex, libssl-dev, libelf-dev
#
# Usage:
#   ./build-pixel8-vanilla-akita.sh [device] [android_version]
#
# Examples:
#   ./build-pixel8-vanilla-akita.sh akita android16
#   ./build-pixel8-vanilla-akita.sh shusky android16
#
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE="${1:-akita}"
ANDROID_VERSION="${2:-android16}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/pixel8-vanilla-build}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
OUTPUT_DIR="$SCRIPT_DIR/out-pixel8-vanilla-$DEVICE"

echo "=========================================="
echo "Pixel 8 Vanilla Kernel Builder"
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
# STEP 3: CONFIGURE KERNEL
# ============================================================================

echo "## Step 3: Configuring kernel..."

cd "$KERNEL_DIR"

# Generate base config
echo "   Generating gki_defconfig..."
make ARCH=arm64 LLVM=1 O=out gki_defconfig

# Apply vanilla configs (performance and I/O optimizations)
echo "   Applying vanilla kernel configs..."
cat >> out/.config <<'EOF'
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

# Run olddefconfig to resolve dependencies
make ARCH=arm64 LLVM=1 O=out olddefconfig

echo "✅ Kernel configured"
echo ""

# ============================================================================
# STEP 4: BUILD KERNEL
# ============================================================================

echo "## Step 4: Building kernel..."

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
  all

if [ ! -f out/arch/arm64/boot/Image ]; then
  echo "❌ Kernel build failed - Image not found"
  exit 1
fi

echo "✅ Kernel built successfully"
echo ""

# ============================================================================
# STEP 5: PACKAGE OUTPUT
# ============================================================================

echo "## Step 5: Packaging output..."

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
Build Type: Vanilla (No KernelSU/SuSFS)
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
echo "     KERNEL_IMAGE=$OUTPUT_DIR/Image ./repack-akita-android16.sh"
echo ""
echo "  2. Flash to device:"
echo "     fastboot boot boot-akita-*.img"
echo "=========================================="

#!/bin/bash
set -e

echo "=========================================="
echo "Simple Akita Android 16 Boot Repacker"
echo "Built-in KernelSU (no ksud patching needed)"
echo "=========================================="

# Configuration
KERNEL_IMAGE="${KERNEL_IMAGE:-kernel/out/arch/arm64/boot/Image}"
KERNEL_IMAGE_LZ4="${KERNEL_IMAGE_LZ4:-kernel/out/arch/arm64/boot/Image.lz4}"
STOCK_BOOT="${STOCK_BOOT:-boot-images/stock-akita-cp1a.260505.005.a1.img}"
MAGISKBOOT="${MAGISKBOOT:-/usr/bin/magiskboot}"
WORK_DIR="$(mktemp -d)"
WORKSPACE="$(pwd)"

# Validate inputs
if [ ! -f "$KERNEL_IMAGE" ]; then
  echo "❌ Kernel Image not found: $KERNEL_IMAGE"
  exit 1
fi

if [ ! -f "$STOCK_BOOT" ]; then
  echo "❌ Stock boot image not found: $STOCK_BOOT"
  exit 1
fi

if [ ! -x "$MAGISKBOOT" ]; then
  echo "❌ magiskboot not found: $MAGISKBOOT"
  exit 1
fi

echo "✅ Kernel Image: $KERNEL_IMAGE ($(du -h "$KERNEL_IMAGE" | cut -f1))"
if [ -f "$KERNEL_IMAGE_LZ4" ]; then
  echo "✅ Kernel Image.lz4: $KERNEL_IMAGE_LZ4 ($(du -h "$KERNEL_IMAGE_LZ4" | cut -f1))"
fi
echo "✅ Stock Boot: $STOCK_BOOT ($(du -h "$STOCK_BOOT" | cut -f1))"
echo "✅ magiskboot: $MAGISKBOOT"

# Get kernel version
cd kernel
KERNEL_VERSION=$(grep "^VERSION" Makefile | cut -d' ' -f3).$(grep "^PATCHLEVEL" Makefile | cut -d' ' -f3).$(grep "^SUBLEVEL" Makefile | cut -d' ' -f3)
echo "📦 Kernel Version: $KERNEL_VERSION"
cd ..

# Copy stock boot to work directory
echo ""
echo "📋 Copying stock boot image to work directory..."
cp "$STOCK_BOOT" "${WORK_DIR}/boot.img"

# Unpack boot image
echo "📦 Unpacking boot image..."
cd "${WORK_DIR}"
"$MAGISKBOOT" unpack boot.img

# Check what kernel format the boot image uses
if [ -f "kernel" ]; then
  KERNEL_SIZE=$(stat -c%s kernel)
  echo "   Original kernel size: $KERNEL_SIZE bytes"
  
  # Check if original kernel is compressed
  file kernel | grep -q "LZ4" && echo "   Original kernel: LZ4 compressed" || echo "   Original kernel: uncompressed"
fi

# Replace kernel
echo "🔄 Replacing kernel..."
if [ -f "$KERNEL_IMAGE_LZ4" ] && file kernel 2>/dev/null | grep -q "LZ4"; then
  echo "   Using LZ4 compressed kernel"
  cp "${WORKSPACE}/${KERNEL_IMAGE_LZ4}" kernel
else
  echo "   Using uncompressed kernel"
  cp "${WORKSPACE}/${KERNEL_IMAGE}" kernel
fi

NEW_KERNEL_SIZE=$(stat -c%s kernel)
echo "   New kernel size: $NEW_KERNEL_SIZE bytes"

# Repack boot image
echo "📦 Repacking boot image..."
"$MAGISKBOOT" repack boot.img new-boot.img

if [ ! -f "new-boot.img" ]; then
  echo "❌ Failed to repack boot image"
  ls -la "${WORK_DIR}/"
  exit 1
fi

# Copy to workspace
BOOT_IMG_NAME="boot-akita-android16-${KERNEL_VERSION}-$(date +%Y%m%d-%H%M%S).img"
cp new-boot.img "${WORKSPACE}/${BOOT_IMG_NAME}"
cd "${WORKSPACE}"

# Generate SHA256 checksum
sha256sum "${BOOT_IMG_NAME}" > "${BOOT_IMG_NAME}.sha256"

# Cleanup
rm -rf "${WORK_DIR}"

echo ""
echo "=========================================="
echo "✅ SUCCESS!"
echo "=========================================="
echo "Repacked boot image: ${BOOT_IMG_NAME}"
echo "Size: $(du -h "${BOOT_IMG_NAME}" | cut -f1)"
echo "SHA256: $(cat "${BOOT_IMG_NAME}.sha256")"
echo ""
echo "To flash on akita device:"
echo "  fastboot flash boot ${BOOT_IMG_NAME}"
echo "  fastboot reboot"
echo "=========================================="

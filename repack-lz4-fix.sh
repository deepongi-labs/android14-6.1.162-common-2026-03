#!/bin/bash
set -e

echo "=========================================="
echo "Akita Android 16 Boot Repacker (LZ4 Fix)"
echo "=========================================="

KERNEL_IMAGE_LZ4="${KERNEL_IMAGE_LZ4:-kernel/out/arch/arm64/boot/Image.lz4}"
STOCK_BOOT="${STOCK_BOOT:-boot-images/stock-akita-cp1a.260505.005.a1.img}"
MAGISKBOOT="${MAGISKBOOT:-/usr/bin/magiskboot}"
WORK_DIR="$(mktemp -d)"
WORKSPACE="$(pwd)"

# Validate
if [ ! -f "$KERNEL_IMAGE_LZ4" ]; then
  echo "❌ Kernel Image.lz4 not found: $KERNEL_IMAGE_LZ4"
  exit 1
fi

if [ ! -f "$STOCK_BOOT" ]; then
  echo "❌ Stock boot image not found: $STOCK_BOOT"
  exit 1
fi

echo "✅ Kernel Image.lz4: $KERNEL_IMAGE_LZ4 ($(du -h "$KERNEL_IMAGE_LZ4" | cut -f1))"
echo "✅ Stock Boot: $STOCK_BOOT ($(du -h "$STOCK_BOOT" | cut -f1))"

# Get kernel version
cd kernel
KERNEL_VERSION=$(grep "^VERSION" Makefile | cut -d' ' -f3).$(grep "^PATCHLEVEL" Makefile | cut -d' ' -f3).$(grep "^SUBLEVEL" Makefile | cut -d' ' -f3)
echo "📦 Kernel Version: $KERNEL_VERSION"
cd ..

# Copy and unpack
cp "$STOCK_BOOT" "${WORK_DIR}/boot.img"
cd "${WORK_DIR}"
"$MAGISKBOOT" unpack boot.img

echo ""
echo "📋 Original boot image info:"
"$MAGISKBOOT" unpack -n boot.img 2>&1 | grep -E "KERNEL|RAMDISK|HEADER|CMDLINE"

# Replace with LZ4 kernel directly
echo ""
echo "🔄 Replacing kernel with Image.lz4..."
cp "${WORKSPACE}/${KERNEL_IMAGE_LZ4}" kernel

echo "   New kernel: $(file kernel)"
echo "   New kernel size: $(stat -c%s kernel) bytes"

# Repack
echo ""
echo "📦 Repacking boot image..."
"$MAGISKBOOT" repack boot.img new-boot.img

if [ ! -f "new-boot.img" ]; then
  echo "❌ Failed to repack"
  exit 1
fi

# Verify repacked image
echo ""
echo "📋 Repacked boot image info:"
"$MAGISKBOOT" unpack -n new-boot.img 2>&1 | grep -E "KERNEL|RAMDISK|HEADER|CMDLINE"

BOOT_IMG_NAME="boot-akita-android16-${KERNEL_VERSION}-lz4-$(date +%Y%m%d-%H%M%S).img"
cp new-boot.img "${WORKSPACE}/${BOOT_IMG_NAME}"
cd "${WORKSPACE}"

sha256sum "${BOOT_IMG_NAME}" > "${BOOT_IMG_NAME}.sha256"
rm -rf "${WORK_DIR}"

echo ""
echo "=========================================="
echo "✅ Boot image created: ${BOOT_IMG_NAME}"
echo "Size: $(du -h "${BOOT_IMG_NAME}" | cut -f1)"
echo "SHA256: $(cat "${BOOT_IMG_NAME}.sha256")"
echo "=========================================="

#!/usr/bin/env bash
set -euo pipefail

DEVICE="${1:-akita}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="/mnt/Android/pixel8-make-build/${DEVICE}-android16/aosp"
OUTPUT_DIR="$SCRIPT_DIR/out-pixel8-make-$DEVICE"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

CLANG_BIN="/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin"
GCC64_BIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu/bin"
GCC32_BIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi/bin"

function build_make() {
  make -j"$MAKE_JOBS" \
    ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="ccache $CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
    AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm" \
    OBJCOPY="$CLANG_BIN/llvm-objcopy" OBJDUMP="$CLANG_BIN/llvm-objdump" \
    READELF="$CLANG_BIN/llvm-readelf" STRIP="$CLANG_BIN/llvm-strip" \
    HOSTCC="ccache $CLANG_BIN/clang" HOSTCXX="ccache $CLANG_BIN/clang++" \
    HOSTLD="$CLANG_BIN/ld.lld" HOSTAR="$CLANG_BIN/llvm-ar" \
    CLANG_TRIPLE="aarch64-linux-gnu-" \
    CROSS_COMPILE="$GCC64_BIN/aarch64-none-linux-gnu-" \
    CROSS_COMPILE_COMPAT="$GCC32_BIN/arm-none-eabi-" \
    KCFLAGS="-Wno-error" \
    "$@"
}

echo "## Step 1: Applying module check bypass..."

cd "$KERNEL_DIR"
cp -f kernel/module/version.c kernel/module/version.c.cleanbak 2>/dev/null || true

sed -i '/^int same_magic(const char \*amagic/a\    return 1;' kernel/module/version.c
sed -i '/^int check_version(const struct load_info \*info/a\    return 1;' kernel/module/version.c

echo "  same_magic() and check_version() patched"
echo ""

echo "## Step 2: Configuring kernel..."
cd "$KERNEL_DIR"
rm -rf out/
build_make O=out gki_defconfig
echo "# CONFIG_MODULE_SIG is not set" >> out/.config
build_make O=out olddefconfig
echo "  configured with gki_defconfig, module sig disabled"
echo ""

echo "## Step 3: Building kernel (this will take 20-60 minutes)..."
build_make O=out Image
echo ""

if [ ! -f out/arch/arm64/boot/Image ]; then
    echo "Build failed!"
    exit 1
fi

echo "## Step 4: Copying output..."
mkdir -p "$OUTPUT_DIR"
cp -v out/arch/arm64/boot/Image "$OUTPUT_DIR/"
command -v lz4 >/dev/null 2>&1 && lz4 -9 -f out/arch/arm64/boot/Image "$OUTPUT_DIR/Image.lz4"
cp -v out/.config "$OUTPUT_DIR/config"

KERNEL_VERSION=$(cat out/include/config/kernel.release 2>/dev/null || echo "unknown")
cat > "$OUTPUT_DIR/build-info.txt" <<EOF
Build: CLEAN GKI (no mods)
Device: $DEVICE
Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Version: $KERNEL_VERSION
Module checks: bypassed
EOF

echo ""
echo "BUILD COMPLETE"
echo "Kernel: $OUTPUT_DIR/Image"
echo "Repack: export KERNEL_IMAGE=\"$OUTPUT_DIR/Image\" && ./repack-simple.sh"

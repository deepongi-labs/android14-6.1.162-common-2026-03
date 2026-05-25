#!/bin/bash
set -e

echo "=========================================="
echo "Akita Android 16 Boot Image Repacker"
echo "=========================================="

# Configuration
KERNEL_IMAGE="${KERNEL_IMAGE:-kernel/out/arch/arm64/boot/Image}"
STOCK_BOOT="${STOCK_BOOT:-boot-images/stock-akita-cp1a.260505.005.a1.img}"
TIANN_REPO_URL="https://github.com/tiann/KernelSU"
TIANN_REF="${TIANN_REF:-main}"
REPACK_DIR="$(mktemp -d)"
WORKSPACE="$(pwd)"

# Validate inputs
if [ ! -f "$KERNEL_IMAGE" ]; then
  echo "❌ Kernel Image not found: $KERNEL_IMAGE"
  echo "   Please build the kernel first or specify KERNEL_IMAGE path"
  exit 1
fi

if [ ! -f "$STOCK_BOOT" ]; then
  echo "❌ Stock boot image not found: $STOCK_BOOT"
  echo "   Please download stock akita Android 16 boot.img or specify STOCK_BOOT path"
  exit 1
fi

echo "✅ Kernel Image: $KERNEL_IMAGE ($(du -h "$KERNEL_IMAGE" | cut -f1))"
echo "✅ Stock Boot: $STOCK_BOOT ($(du -h "$STOCK_BOOT" | cut -f1))"

# Get kernel version
cd kernel
KERNEL_VERSION=$(grep "^VERSION" Makefile | cut -d' ' -f3).$(grep "^PATCHLEVEL" Makefile | cut -d' ' -f3).$(grep "^SUBLEVEL" Makefile | cut -d' ' -f3)
echo "📦 Kernel Version: $KERNEL_VERSION"
cd ..

# Check if ksud already exists
KSUD=""
if [ -f "kernel/KernelSU/target/release/ksud" ]; then
  KSUD="kernel/KernelSU/target/release/ksud"
  echo "✅ Found existing ksud: $KSUD"
elif [ -f ".tiann-ksu-src/target/release/ksud" ]; then
  KSUD=".tiann-ksu-src/target/release/ksud"
  echo "✅ Found existing ksud: $KSUD"
fi

# Build ksud if not found
if [ -z "$KSUD" ] || [ ! -x "$KSUD" ]; then
  echo "🔨 Building ksud from Tiann KernelSU source..."
  
  # Determine KernelSU source location
  if [ -f "kernel/KernelSU/Cargo.toml" ]; then
    TIANN_KSUD_STAGE="kernel/KernelSU"
    echo "   Using existing KernelSU in kernel tree"
  else
    TIANN_KSUD_STAGE=".tiann-ksu-src"
    if [ ! -d "$TIANN_KSUD_STAGE" ]; then
      echo "   Cloning Tiann KernelSU..."
      git clone --depth=1 --branch "$TIANN_REF" "$TIANN_REPO_URL" "$TIANN_KSUD_STAGE" \
        || git clone --depth=1 "$TIANN_REPO_URL" "$TIANN_KSUD_STAGE"
    fi
  fi

  # Patch boot_patch.rs to skip kernel module installation (built-in KSU)
  echo "   Patching boot_patch.rs for built-in KernelSU..."
  python3 - "${TIANN_KSUD_STAGE}/userspace/ksud/src/boot_patch.rs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_kmod = "\n".join([
    '        let kmod_file = workdir.join("kernelsu.ko");',
    '        if let Some(kmod) = kmod {',
    '            std::fs::copy(kmod, kmod_file).context("copy kernel module failed")?;',
    '        } else if !no_install {',
    '            // If kmod is not specified, extract from assets',
    '            println!("- KMI: {kmi}");',
    '            let name = format!("{kmi}_kernelsu.ko");',
    '            assets::copy_assets_to_file(&name, kmod_file)',
    '                .with_context(|| format!("Failed to copy {name}"))?;',
    '        }',
    '',
])
new_kmod = "\n".join([
    '        let install_kmod = kmod.is_some();',
    '        let kmod_file = workdir.join("kernelsu.ko");',
    '        if let Some(kmod) = kmod {',
    '            std::fs::copy(kmod, kmod_file).context("copy kernel module failed")?;',
    '        }',
    '',
])
old_add = "\n".join([
    '            do_cpio_cmd(',
    '                &magiskboot,',
    '                workdir,',
    '                ramdisk,',
    '                "add 0755 kernelsu.ko kernelsu.ko",',
    '            )?;',
    '',
])
new_add = "\n".join([
    '            if install_kmod {',
    '                do_cpio_cmd(',
    '                    &magiskboot,',
    '                    workdir,',
    '                    ramdisk,',
    '                    "add 0755 kernelsu.ko kernelsu.ko",',
    '                )?;',
    '            }',
    '',
])
text = text.replace(old_kmod, new_kmod)
text = text.replace('            println!("- Adding KernelSU LKM");', '            println!("- Adding KernelSU init for built-in KSU kernel");')
text = text.replace(old_add, new_add)
path.write_text(text)
PY

  # Check for cargo
  if ! command -v cargo >/dev/null; then
    echo "❌ cargo not found. Please install Rust toolchain:"
    echo "   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
  fi

  # Setup Rust toolchain
  echo "   Setting up Rust toolchain..."
  rustup default stable
  rustup target add aarch64-unknown-linux-musl

  # Find aarch64 linker
  KSUINIT_LINKER=""
  for linker in \
    "${WORKSPACE}/kernel/prebuilts-master/clang/host/linux-x86/clang-r522817/bin/aarch64-linux-gnu-gcc" \
    "$(command -v aarch64-linux-gnu-gcc 2>/dev/null || true)" \
    "$(command -v aarch64-linux-android-gcc 2>/dev/null || true)"; do
    if [ -x "$linker" ]; then
      KSUINIT_LINKER="$linker"
      break
    fi
  done

  if [ -z "$KSUINIT_LINKER" ]; then
    echo "❌ aarch64 linker not found. Please install:"
    echo "   sudo apt-get install gcc-aarch64-linux-gnu"
    exit 1
  fi
  echo "   Using linker: $KSUINIT_LINKER"

  # Build ksuinit
  echo "   Building ksuinit..."
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$KSUINIT_LINKER" \
    cargo build --manifest-path "${TIANN_KSUD_STAGE}/Cargo.toml" --release -p ksuinit --target aarch64-unknown-linux-musl

  mkdir -p "${TIANN_KSUD_STAGE}/userspace/ksud/bin/aarch64"
  cp "${TIANN_KSUD_STAGE}/target/aarch64-unknown-linux-musl/release/ksuinit" \
    "${TIANN_KSUD_STAGE}/userspace/ksud/bin/aarch64/ksuinit"

  # Build ksud
  echo "   Building ksud..."
  cargo fix --manifest-path "${TIANN_KSUD_STAGE}/Cargo.toml" --bin "ksud" -p ksud --allow-dirty || true
  cargo build --manifest-path "${TIANN_KSUD_STAGE}/Cargo.toml" --release -p ksud

  KSUD="${TIANN_KSUD_STAGE}/target/release/ksud"
  if [ ! -x "$KSUD" ]; then
    echo "❌ Failed to build ksud"
    exit 1
  fi
  echo "✅ Built ksud: $KSUD"
fi

# Copy stock boot image to repack directory
echo "📋 Copying stock boot image..."
cp "$STOCK_BOOT" "${REPACK_DIR}/stock_boot.img"

# Patch boot image with ksud
echo "🔧 Patching boot.img with ksud boot-patch..."
"$KSUD" boot-patch \
  -b "${REPACK_DIR}/stock_boot.img" \
  -k "${WORKSPACE}/${KERNEL_IMAGE}" \
  --no-install \
  -o "${REPACK_DIR}"

# Find patched image
PATCHED_IMG=$(find "${REPACK_DIR}" -name '*patched*boot*' -o -name 'new-boot.img' | head -1)
if [ -z "$PATCHED_IMG" ] || [ ! -f "$PATCHED_IMG" ]; then
  echo "❌ ksud boot-patch did not produce a patched image"
  echo "   Contents of repack directory:"
  ls -la "${REPACK_DIR}/"
  exit 1
fi

# Generate output filename
BOOT_IMG_NAME="boot-akita-android16-${KERNEL_VERSION}-$(date +%Y%m%d).img"
cp "$PATCHED_IMG" "${WORKSPACE}/${BOOT_IMG_NAME}"

# Generate SHA256 checksum
cd "${WORKSPACE}"
sha256sum "${BOOT_IMG_NAME}" > "${BOOT_IMG_NAME}.sha256"

# Cleanup
rm -rf "${REPACK_DIR}"

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
echo "=========================================="

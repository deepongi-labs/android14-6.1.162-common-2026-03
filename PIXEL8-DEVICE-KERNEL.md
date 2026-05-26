# Pixel 8 Device-Specific Kernel Build Guide

## Why GKI Kernels Don't Boot on Pixel 8

### The Problem
The standard GKI (Generic Kernel Image) build in `.github/workflows/kernel-build.yml` produces a **generic kernel** that lacks device-specific drivers, device trees, and configurations required for Pixel 8 series devices to boot.

**Symptoms:**
- Kernel flashes successfully but device won't boot
- Stuck at bootloader or Google logo
- No error messages visible without serial console

### GKI vs Device-Specific Kernels

| Aspect | GKI Kernel | Device-Specific Kernel |
|--------|-----------|------------------------|
| **Source** | `android.googlesource.com/kernel/common` | `android.googlesource.com/kernel/manifest` |
| **Build System** | Make | Bazel/Kleaf |
| **Device Trees** | ❌ Generic only | ✅ Pixel 8 specific (akita/shiba/husky) |
| **Drivers** | ❌ Generic only | ✅ Tensor G3, display, camera, sensors |
| **Boot on Pixel 8** | ❌ No | ✅ Yes |
| **Size** | ~35MB | ~40-50MB |

### What's Missing in GKI

The GKI kernel lacks:
1. **Tensor G3 SoC drivers** - CPU, GPU, NPU, TPU
2. **Display drivers** - Samsung AMOLED panel drivers
3. **Camera drivers** - Pixel 8 camera subsystem
4. **Sensor drivers** - Accelerometer, gyroscope, proximity
5. **Device trees** - Hardware description for akita/shiba/husky
6. **Vendor-specific configs** - Google-specific kernel configs

## Building Device-Specific Pixel 8 Kernel

### Prerequisites

**System Requirements:**
- 50GB+ free disk space
- 16GB+ RAM recommended
- Fast internet connection (will download ~10-20GB)

**Software:**
```bash
# Arch/EndeavourOS
sudo pacman -S base-devel bc bison flex git curl python ccache lz4

# Install repo tool
sudo curl https://storage.googleapis.com/git-repo-downloads/repo \
  -o /usr/local/bin/repo
sudo chmod +x /usr/local/bin/repo
```

### Quick Start

```bash
# Build for Pixel 8a (akita)
./build-pixel8-enhance.sh akita android16

# Build for Pixel 8 (shiba)
./build-pixel8-enhance.sh shiba android16

# Build for Pixel 8 Pro (husky)
./build-pixel8-enhance.sh husky android16
```

### What the Script Does

1. **Syncs Pixel 8 manifest tree** (~10-30 minutes)
   - Downloads device-specific kernel sources
   - Includes Tensor G3 drivers, device trees, configs

2. **Integrates KernelSU** (tiann variant)
   - Clones KernelSU source
   - Symlinks into kernel tree
   - Wires Kbuild/Kconfig

3. **Integrates SuSFS**
   - Copies SuSFS sources
   - Applies patches for device-specific tree

4. **Configures kernel**
   - Generates gki_defconfig base
   - Adds KernelSU/SuSFS configs
   - Enables MGLRU, Kyber, BFQ

5. **Builds kernel** (~20-60 minutes depending on CPU)
   - Uses LLVM/Clang
   - Parallel build with all CPU cores
   - Generates Image and Image.lz4

6. **Packages output**
   - Copies Image and Image.lz4
   - Saves config and build info

### Output Location

```
out-pixel8-akita/
├── Image           # Uncompressed kernel (35-40MB)
├── Image.lz4       # LZ4 compressed (17-20MB)
├── config          # Kernel config used
└── build-info.txt  # Build metadata
```

### Repacking Boot Image

After building, repack the boot image:

```bash
# Edit repack-simple.sh to use the new kernel
export KERNEL_IMAGE="out-pixel8-akita/Image"
export KERNEL_IMAGE_LZ4="out-pixel8-akita/Image.lz4"

./repack-simple.sh
```

Or manually:

```bash
magiskboot unpack stock-boot.img
cp out-pixel8-akita/Image kernel
magiskboot repack stock-boot.img new-boot.img
```

### Testing

**Safe test without flashing:**
```bash
fastboot boot boot-akita-android16-*.img
```

**Permanent flash:**
```bash
fastboot flash boot boot-akita-android16-*.img
fastboot reboot
```

**Recovery (if boot fails):**
```bash
fastboot flash boot boot-images/stock-akita-cp1a.260505.005.a1.img
fastboot reboot
```

## Troubleshooting

### Build Fails: "repo: command not found"
```bash
sudo curl https://storage.googleapis.com/git-repo-downloads/repo \
  -o /usr/local/bin/repo
sudo chmod +x /usr/local/bin/repo
```

### Build Fails: "No space left on device"
The Pixel 8 kernel tree requires ~50GB. Free up space or use a different partition:
```bash
export WORKSPACE_ROOT="/mnt/large-disk/pixel8-build"
./build-pixel8-enhance.sh akita android16
```

### Kernel Still Won't Boot

1. **Check device match:**
   - akita = Pixel 8a
   - shiba = Pixel 8
   - husky = Pixel 8 Pro

2. **Verify Android version:**
   - Use `android16` for Android 16 Beta
   - Use `android15` for Android 15 stable

3. **Check boot logs:**
   ```bash
   fastboot boot boot-akita-*.img
   # In another terminal:
   adb wait-for-device && adb logcat -b all > boot.log
   ```

4. **Try without KernelSU:**
   Edit `build-pixel8-enhance.sh` and comment out Step 3 (KernelSU integration)

### Manifest Sync Fails

If `repo sync` fails with network errors:
```bash
# Retry with fewer parallel jobs
cd ~/pixel8-enhance-build/akita-android16
repo sync -c -j4 --no-tags --force-sync
```

## Differences from GKI Build

### Source Tree Structure

**GKI Build:**
```
kernel/
├── arch/
├── drivers/
├── fs/
└── ...
```

**Device-Specific Build:**
```
akita-android16/
├── aosp/              # Common kernel (like GKI)
├── private/
│   └── devices/
│       └── google/
│           └── akita/  # Device-specific code
├── prebuilts/
├── tools/
│   └── bazel          # Build system
└── .repo/
```

### Build Commands

**GKI:**
```bash
cd kernel
make ARCH=arm64 LLVM=1 O=out gki_defconfig
make -j$(nproc) ARCH=arm64 LLVM=1 O=out
```

**Device-Specific:**
```bash
cd akita-android16
tools/bazel build //private/devices/google/akita:akita_dist
# Or use the build-pixel8-enhance.sh script
```

## CI/CD Integration

To integrate into GitHub Actions, see `.github/workflows/pixel8-akita-bazel.yml` for reference.

Key differences:
- Requires `repo` tool
- Much longer build time (30-90 minutes)
- Larger artifact size (~100MB vs ~50MB)
- Requires more disk space (50GB vs 10GB)

## References

- [Google Pixel 8 Kernel Source](https://android.googlesource.com/kernel/manifest/+/refs/heads/android-gs-akita-6.1-android16-beta)
- [Kleaf Build System](https://android.googlesource.com/kernel/build/+/refs/heads/main/kleaf/docs/)
- [KernelSU Integration](https://kernelsu.org/guide/how-to-integrate-for-non-gki.html)

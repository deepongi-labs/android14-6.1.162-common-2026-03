# Pixel 8 Series Kernel Builder

[![Kernel](https://img.shields.io/badge/kernel-6.1.162-blue.svg)](https://android.googlesource.com/kernel/common)
[![Android](https://img.shields.io/badge/android-14%20GKI-green.svg)](https://source.android.com/)
[![Devices](https://img.shields.io/badge/devices-akita%20%7C%20shiba%20%7C%20husky-orange.svg)](https://store.google.com/category/phones_pixel)
[![KernelSU](https://img.shields.io/badge/KernelSU-5%20variants-purple.svg)](https://github.com/tiann/KernelSU)
[![SuSFS](https://img.shields.io/badge/SuSFS-10%20features-red.svg)](https://gitlab.com/simonpunk/susfs4ksu)

> Personal build system for custom Android 14 GKI kernels for the Pixel 8 series (Tensor G3).

---

## What's Here

A reusable GitHub Actions workflow that builds GKI kernels with five
KernelSU variants and ships them as flashable AnyKernel3 zips.

### Variants

| Variant | KernelSU upstream | AnyKernel branch | Notes |
|---------|-------------------|------------------|-------|
| `tiann`     | github.com/tiann/KernelSU       | `KernelSU` | Official upstream, pinned to a known-good commit |
| `enhance`   | tiann (same repo)               | `KernelSU` | Tiann + extra UX patches (LKM-mode spoof) |
| `kowsu`     | github.com/KOWX712/KernelSU     | `KowSU`    | KOWX712's fork |
| `resukisu`  | github.com/ReSukiSU/ReSukiSU    | `resukisu` | ReSukiSU |
| `next`      | github.com/KernelSU-Next/KernelSU-Next | `next` | KernelSU-Next development branch |

### Devices Supported

* Pixel 8 (`shiba`)
* Pixel 8a (`akita`)
* Pixel 8 Pro (`husky`)

All three share Tensor G3 (1× Cortex-X3 + 4× Cortex-A715 + 4× Cortex-A510),
so the same Image works on every device.

## Workflows

| Workflow | Purpose |
|----------|---------|
| `kernel-build.yml`         | Reusable. Builds one or all variants. Drives matrix, patch manifest gate, packaging. |
| `enhance-kernel-build.yml` | Dispatcher — builds **only** the `enhance` variant with full per-build knobs. |
| `drift-check.yml`          | Weekly Mon 06:00 UTC — dry-runs `enhance` + `tiann` against `tiann/master` to catch upstream drift early. |
| `manager-build.yml`        | Builds the KernelSU manager APK. |

## Tuning Knobs

Inputs you can set when dispatching the workflow:

* `tuning_profile` — `balanced` (default) / `performance` / `battery`
* `lto_mode` — `thin` (default) / `full` / `none`
* `governor_mode` — `dynasched` (default; renames schedutil to a Pixel-8-aware name) / `stock_schedutil`
* `kerneltoast_patch_policy` — `strict` / `best_effort` (default) / `off`
* `strict_susfs` — fail the build if any SuSFS patch auto-disables or drifts (default: false)
* `apply_oneplus12_wifi_patch` — opt-in legacy patch (default: false; Pixel 8 uses a different chipset)
* `force_clean_build` — runs `mrproper` before defconfig (default: false)
* `dry_run_only` — sync + patch + verify, skip compile (default: false)
* `include_runtime_tuner` — generate the on-device dynasched tuner script (default: true)

Source pin overrides:

* `kernel_ref`  default `android14-6.1-2026-03`
* `susfs_ref`   default `gki-android14-6.1-dev`
* `tiann_ref`   default pinned commit (bump deliberately)
* `kowsu_ref`, `resukisu_ref`, `next_ref` — branches

## What Gets Built

For each variant the run produces:

* `AK3-<kver>-<variant>-r<KSU_VERSION>.zip` — flashable in Kernel Flasher / fastboot via AnyKernel3
* `AK3-…zip.sha256` — release-time integrity check
* `Image.lz4` — pre-compressed kernel image for boot.img patching
* `pixel8-runtime-tuner-<variant>.sh` — root service.d script for runtime governor/cluster tuning
* `source-manifest-<variant>.txt` — kernel.release, KMI generation, build time, refs
* `patch-manifest-<variant>.txt` — every patch and how it applied (`applied`, `applied-fuzz`, `applied-3way`, `already-present`, `disabled`, `failed`)
* Build log, `out/.config`, profile fragment, headers_install log

The runtime tuner auto-detects the governor (dynasched/schedutil) and cluster
topology (X3/A715/A510 by `cpuinfo_max_freq`) so the same script works on
Pixel 8 / 8a / 8 Pro without configuration.

## SuSFS

When enabled, all 10 features are activated:

```
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
```

The SuSFS patch pipeline is multi-stage: it tries the variant-specific
patch, falls back to the upstream susfs4ksu patch, and applies Python-based
fuzzing/3-way merge for stale hunks. Drift is reported in the patch manifest
and gated by `strict_susfs`.

## Self-hosted Runner

Reference toolchain layout (override via env if you build elsewhere):

* Clang: `/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin`
* aarch64 GNU 15.2.rel1
* arm GNU 15.2.rel1
* ccache: `/mnt/ccache/.ccache` (50G cap, persistent)
* Source mirrors: `/mnt/Android/source-mirrors`

The workflow falls back to distro `/usr/lib/llvm-17/bin` when the
self-hosted layout is not present, so dispatching on `ubuntu-latest` works
for dry-runs.

## Notes

* Branch name says "android14" but stock Pixel 8 ships Android 14 / 15 / 16 with this kernel base.
* All five variants tested on Pixel 8a (akita); shiba/husky verified by topology share.
* Performance default favours sustained workloads (HZ=300, UCLAMP_TASK, MGLRU). Battery profile uses HZ=250 + CPU_IDLE + MGLRU.

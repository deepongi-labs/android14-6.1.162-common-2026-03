# Pixel 8 Series Kernel Builder

[![Build Status](https://img.shields.io/github/actions/workflow/status/deepongi-labs/android14-6.1.157-common-2025-12/kernel-build.yml)](https://github.com/deepongi-labs/android14-6.1.157-common-2025-12/actions) [![Kernel](https://img.shields.io/badge/kernel-6.1.157-blue.svg)](https://github.com/aosp-mirror/kernel_common) [![Android](https://img.shields.io/badge/android-16-green.svg)](https://source.android.com/) [![Device](https://img.shields.io/badge/device-Pixel%208%20Series-orange.svg)](https://store.google.com/product/pixel_8a) [![KernelSU](https://img.shields.io/badge/KernelSU-3%20variants-purple.svg)](https://github.com/tiann/KernelSU) [![SuSFS](https://img.shields.io/badge/SuSFS-10%20features-red.svg)](https://gitlab.com/simonpunk/susfs4ksu) [![Build Time](https://img.shields.io/badge/build%20time-~4--5min-brightgreen.svg)](../../actions) [![CCache](https://img.shields.io/badge/ccache-92%25%2B-yellow.svg)](#)

> My personal build system for custom Android 16 kernels.

---

## What's Here

Automated GitHub Actions workflow that builds GKI kernels with three KernelSU variants:
* **tiann** (official)
* **kowsu** (fork)
* **mksu** (fork)

## Quick Run

Takes about **14-15 minutes total** for all three variants.

## What Gets Built

Flashable kernel ZIPs for Pixel 8a (works on 8/8 Pro too):
* Android 16
* Kernel 6.1.157
* KernelSU integrated
* Optional SuSFS for root hiding

## Current Status

**Version:** v4.1

**Optimizations:**
* Parallel downloads
* Smart CPU/RAM detection
* 92%+ cache hit rate
* Build time tracking

**Performance:**
* ~4-5 min per variant
* ~14-15 min for all three

## Setup

### Self-hosted Runner

**System:**
* **OS:** EndeavourOS (Arch-based)
* **Kernel:** 6.17.9-arch1-1
* **Desktop:** Cinnamon 6.4.13

**Hardware:**
* **CPU:** AMD Ryzen 7 2700 (8-core/16-thread @ 4.0 GHz)
* **RAM:** 32 GB DDR4
* **GPU:** NVIDIA GeForce RTX 2060
* **Motherboard:** MSI X470 GAMING PLUS MAX

**Storage:**
* **System:** 238 GB TeamGroup SSD (ext4)
* **Cache:** Multiple NVMeS/SSDs totaling 4.34 TB
* **CCache:** Local persistent storage

**Build Environment:**
* **Clang:** 22 at `/mnt/Android/clang-22`
* **CCache:** `/mnt/ccache/.ccache` (persistent)
* **ARM64 Toolchain:** GNU 14.3.rel1 at `/mnt/Hawai/toolchains/`
* **ARM32 Toolchain:** GNU 14.3.rel1 at `/mnt/Hawai/toolchains/`

### Submodules

* **kernel:** Google GKI (android14-6.1-2025-12)
* **susfs4ksu:** SuSFS framework

## Features

* Multi-variant builds
* Comprehensive changelogs
* Telegram notifications
* Auto versioning
* SHA256/MD5 checksums
* Build time profiling

## Notes

* Kernel branch name says "android14" but this is for Android 16
* Compatible with all Pixel 8 series (same Tensor G3)
* All tested on my 8a
* SuSFS with all 10 available features enabled

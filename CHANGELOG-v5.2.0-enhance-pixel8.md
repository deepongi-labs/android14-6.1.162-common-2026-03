# Workflow v5.2.0 - Pixel 8 Series Enhance Improvements

**Base:** v5.1.0 (5-variant build with patch manifest)
**Date:** May 2026
**Status:** Production Ready

This changelog covers a focused round of fixes and additions to the
`enhance` variant build pipeline for Pixel 8 series (akita / shiba / husky)
running Tensor G3.

---

## Critical Correctness Fixes

### Runtime tuner: correct cpufreq policy IDs
The previous tuner wrote to `policy0` / `policy4` / `policy6` / `policy7`,
which silently no-ops on Tensor G3 (which exposes `policy0` for A510,
`policy4` for A715 and `policy8` for the X3 prime core).

The tuner now auto-discovers all `/sys/devices/system/cpu/cpufreq/policy*`
entries on boot and classifies each by `cpuinfo_max_freq`:
* >= 2.7 GHz -> Cortex-X3 prime
* >= 2.2 GHz -> Cortex-A715 mid
* otherwise  -> Cortex-A510 little

Per-cluster rate-limits and frequency caps are then derived from the
selected mode (eco / balanced / turbo).

### AnyKernel device assertion now covers the full series
Was: `grep -Eiq 'akita'`. Now: `grep -Eiq 'akita|shiba|husky'`.
This allows packaging for Pixel 8 (`shiba`) and Pixel 8 Pro (`husky`),
not just Pixel 8a.

### force_clean_build no longer wipes injected configs
`make clean` ran AFTER `gki_defconfig` + olddefconfig, deleting `out/.config`
along with the appended Pixel 8 / SuSFS / LTO config fragments. Force-clean
now uses `mrproper` BEFORE defconfig.

### debug-info workaround extended to enhance
`enhance` shares the tiann KernelSU base and is susceptible to the same
ld.lld DWARF link crash. `CONFIG_DEBUG_INFO=n` is now applied to both
`tiann` and `enhance`.

### Static-key symbol parity for SuSFS sdcard-decrypted
The enhance core SuSFS patch references
`susfs_is_sdcard_android_data_not_decrypted` (a `static_key_true`) while
the workflow injection only defined
`susfs_set_sdcard_android_data_decrypted_key_false`. Both symbols are now
defined so kowsu/next/resukisu and tiann/enhance link cleanly.

---

## CI / Build Plumbing

### Patch Manifest Gate
A new step parses `logs/patch-manifest-<variant>.txt` after sync+patch:
* `failed`              -> hard fail
* `disabled` (auto-off) -> warning; hard fail in `strict_susfs=true`
* `skipped-stale`       -> warning; hard fail in strict mode
* `applied-fuzz`/`applied-3way` -> reported in step summary

A summary table is written to `$GITHUB_STEP_SUMMARY` with counts per
status plus the final `SuSFS shipped: yes/no`.

### `strict_susfs` input
New boolean (default `false`). Wired through `kernel-build.yml`
(workflow_dispatch + workflow_call) and exposed in `enhance-kernel-build.yml`.

### Weekly drift check (`drift-check.yml`)
Mon 06:00 UTC cron + manual dispatch. Runs `enhance` and `tiann` in
dry-run mode against `tiann/master`, with `strict_susfs=true`, so any
drift on upstream KernelSU breaks CI before a release attempt.

### `kernel/out` cache between runs
`actions/cache/restore` + `actions/cache/save`, keyed on
variant+profile+lto+susfs+toolchain+manifest_hash. Skipped on
`force_clean_build=true`. Significantly speeds incremental builds on
self-hosted runners.

### Concurrency cancel on workflow_dispatch
`cancel-in-progress` is now `true` for manual dispatches and `false` for
`workflow_call` invocations (so matrix children don't kill each other).

### `tiann_ref` documentation
The pinned commit `0544f475…` is now annotated explaining what it
corresponds to and how to live-track upstream (`master`).

---

## Build Output

### `Image.lz4` alongside `Image`
The Pixel 8 stock `boot.img` carries an lz4-compressed kernel.
`lz4 -l -12 --favor-decSpeed` is run after build and the compressed image
is shipped both into the AnyKernel3 zip and as a top-level artifact for
manual `boot.img` patching.

### sha256 next to every zip
`AK3-…zip.sha256` is generated at package time and uploaded alongside the
zip. Release assets pick up `*.sha256` automatically (nullglob-safe).

### KMI / kernel.release in source-manifest
Captured from `out/include/config/kernel.release` and `out/.config`
(`CONFIG_VERSION`, `CONFIG_KMI_GENERATION`). Surfaces the most common
"non-bootable kernel because vendor partition mismatch" cause directly in
the run summary.

### `headers_install` smoke check
Best-effort `make headers_install` after build. Fails the build only if
fewer than 100 UAPI headers are exported (a real regression). Non-fatal
on any other failure; log uploaded as artifact.

---

## Pixel 8 / Tensor G3 Tuning

### MGLRU enabled in all profiles
`CONFIG_LRU_GEN=y` + `CONFIG_LRU_GEN_ENABLED=y` added to balanced /
performance / battery profile fragments. Measurable battery + app-revisit
gains on Tensor G3.

### Kyber and BFQ I/O schedulers
Added `CONFIG_MQ_IOSCHED_KYBER=y`, `CONFIG_IOSCHED_BFQ=y`,
`CONFIG_BFQ_GROUP_IOSCHED=y` to the global config injection. The runtime
tuner switches UFS lanes to `kyber` under turbo profile.

### Runtime tuner: thermal stage + governor re-application
* Applies `step_wise` policy to `BIG_*` / `PRIME_*` / TPU thermal zones
  on boot for less aggressive sustained-load throttling.
* Re-applies `scaling_governor` every loop iteration so the Android
  PowerHAL cannot silently revert dynasched/schedutil on screen state
  changes.
* Multiple-backlight fallback for `is_screen_off` (Pixel 8 / 8a / 8 Pro
  panel sysfs paths differ).
* Fixed-point load math (`load*100`) so 0.95 average isn't truncated to
  `0` and turbo mode actually triggers under sustained burst.
* Per-cluster rate-limit defaults: X3 4ms up / 12ms down, A715 8/20,
  A510 16/40 in balanced mode. Eco/turbo scale these accordingly.

### Optional OnePlus 12 Wi-Fi patch
Previously hard-applied. Now opt-in via `apply_oneplus12_wifi_patch=true`
(default `false`). Documented as legacy parity since Pixel 8 uses a
Synaptics/Broadcom WLAN chipset, not Qualcomm sm8650.

### dynasched patch hardened
Previous patch had a `@@ -861,1 +861,1 @@` hunk header with no context,
which is fragile against minor source drift. Replaced with a properly
contextualised hunk and a docstring explaining the relationship to the
runtime tuner.

---

## Migration

* Re-trigger any in-progress build dispatches: input set has changed
  (added `strict_susfs`, `apply_oneplus12_wifi_patch`).
* If you ship the runtime tuner, re-flash to pick up the rewritten
  `pixel8-runtime-tuner-<variant>.sh`.
* AnyKernel3 zips for shiba/husky no longer fail device assertion if the
  AK3 branch's `anykernel.sh` includes any of `akita|shiba|husky`.
* The Wi-Fi patch is now off by default. Enable explicitly if you have
  evidence it helps your build.

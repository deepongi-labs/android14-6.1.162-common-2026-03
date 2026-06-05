# Enhance KernelSU Patch Set

This variant is a curated composition intended to keep tiann-level stability while
carrying selected compatibility and UX improvements used across other variants.

## Current Composition

- `10_enable_susfs_for_ksu.patch`: KernelSU+SuSFS integration baseline (synced from susfs4ksu)
- `50_add_susfs_in_gki-android14-6.1.patch`: Core SuSFS kernel integration (synced from susfs4ksu)
- `20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch`: Manager UX compatibility tweak (enhance-specific)

## KernelSU Version Compatibility

**Required KernelSU Version:** `da8e0ab1786dc55cce3ed4ff4c304be614e0fa0a` (`da8e0ab1`, `kernel: refine symbol_resolver`)

The synced SuSFS KernelSU patch matches this KernelSU commit exactly. Using older release tags or newer arbitrary commits may cause patch application failures due to KernelSU structural changes.

## Patch Source

Patches are synced from the [susfs4ksu](https://github.com/simonpunk/susfs4ksu) repository,
branch `gki-android14-6.1-dev`, which provides the most up-to-date SuSFS integration for
android14-6.1 GKI kernels.

## Design Goals

- Prefer stable baseline patches that apply cleanly across kernel/common ref updates
- Use KernelSU release tags for predictable patch compatibility
- Add cross-variant improvements only when they can be validated without regressions
- Maintain synchronization with upstream susfs4ksu for security and feature updates

## Known Limitations

With KernelSU `da8e0ab1`, the KernelSU-side SuSFS patch applies cleanly.
The core kernel patch may still produce the known `fs/namespace.c` hunk reject; the workflow
applies `.github/patches/common/namespace_fix_for_tiann.patch` automatically and verifies
that no other rejects remain.

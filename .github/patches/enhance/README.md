# Enhance KernelSU Patch Set

This variant is a curated composition intended to keep tiann-level stability while
carrying selected compatibility and UX improvements used across other variants.

## Current Composition

- `10_enable_susfs_for_ksu.patch`: KernelSU+SuSFS integration baseline (synced from susfs4ksu)
- `50_add_susfs_in_gki-android14-6.1.patch`: Core SuSFS kernel integration (synced from susfs4ksu)
- `20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch`: Manager UX compatibility tweak (enhance-specific)

## KernelSU Version Compatibility

**Required KernelSU Version:** `v3.2.4` (release tag)

The SuSFS patches are designed to work with KernelSU release tags, not arbitrary commits.
Using non-release commits may cause patch application failures due to structural changes.

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

When using KernelSU v3.2.4, some patch hunks may fail due to minor code differences:
- `kernel/core/init.c`: 4 out of 8 hunks may fail
- `kernel/feature/selinux_hide.c`: File doesn't exist in v3.2.4 (can be ignored)
- `kernel/policy/allowlist.c`: 1 hunk may fail
- `kernel/policy/app_profile.c`: 1 hunk may fail
- `fs/namespace.c`: 1 hunk may fail

These failures are minor and do not prevent successful kernel builds. The workflow includes
fallback mechanisms to handle patch failures gracefully.

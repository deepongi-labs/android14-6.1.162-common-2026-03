# Enhance KernelSU Patch Set

This variant is a curated composition intended to keep tiann-level stability while
carrying selected compatibility and UX improvements used across other variants.

Current composition:
- `10_enable_susfs_for_ksu.patch`: tiann-based KernelSU+SuSFS integration baseline.
- `50_add_susfs_in_gki-android14-6.1.patch`: tiann-based core SuSFS integration baseline.
- `20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch`: manager UX compatibility tweak.

Design goal:
- Prefer stable baseline patches that apply cleanly across kernel/common ref updates.
- Add cross-variant improvements only when they can be validated without regressions.

# Dynasched Manager

Dedicated Android app for this kernel only.

What it does:

- detects whether the running kernel exposes the `dynasched` cpufreq governor
- verifies the running kernel matches the expected management surface
- reads current governor state, live telemetry, and per-policy rate-limit nodes
- applies the same `eco`, `balanced`, and `turbo` profiles used by the repo's runtime tuner
- applies and stores custom per-policy tuning
- exports and imports tuning/boot settings as JSON
- optionally reapplies the last selected profile after boot with delay, unlock wait, and rollback safeguards
- fetches the latest GitHub release metadata and can enqueue the latest ZIP asset download
- produces a diagnostics/support report directly from live sysfs state

What it does not try to be:

- a generic kernel manager
- a module flasher
- a governor editor for arbitrary kernels

Project layout:

- `app/` Android application module
- `app/src/main/java/com/deepongi/dynaschedmanager/KernelManager.kt` root-backed sysfs logic
- `app/src/main/java/com/deepongi/dynaschedmanager/BootReceiver.kt` boot reapply path
- `app/src/main/java/com/deepongi/dynaschedmanager/MainActivity.kt` Compose UI and management panels

Expected runtime assumptions:

- rooted device with working `su`
- this kernel exposing `/sys/devices/system/cpu/cpufreq/policy*/dynasched`
- Android 12 or newer

Build notes:

- this is a standalone Android subproject under `kernel-manager-app/`
- if you want wrapper files, run `gradle wrapper` from this directory in a normal Android/Gradle environment

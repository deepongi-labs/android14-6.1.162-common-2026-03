# Copilot instructions for this repository

Purpose: give future Copilot sessions concise, actionable facts about how to build, validate, and reason about this repo.

---

## Quick build / test / lint commands

- Populate submodules (required):
  - git submodule update --init --recursive

- Pre-commit checks used by maintainers:
  - git diff --check          # whitespace / patch formatting
  - git status --short       # confirm changed files

- Local kernel config + full build (single local build):
  - cd kernel && make O=out gki_defconfig
  - cd kernel && make -j"$(nproc)" LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld O=out CC="ccache clang"

- Dirty (incremental) build (workflow knob: `dirty_build: true`):
  - preserve `out/` and avoid mrproper between runs; use same make line as above

- Single-target build (quick iteration):
  - cd kernel && make O=out gki_defconfig && make -j1 O=out Image      # single-threaded quick compile of the kernel image

- Patch and style checks (kernel patches live in kernel/ submodule):
  - kernel/scripts/checkpatch.pl --strict path/to/patch           # run checkpatch from kernel source
  - git diff --check                                            # before committing

- Workflow / canonical build: inspect and run .github/workflows/kernel-build.yml on GitHub Actions — the Actions matrix is the source of truth for variant packaging and release artifacts.

Notes:
- There is no unit-test suite; verification is build-oriented. Use `dry_run_only` dispatch (workflow input) to run sync + patch + verify without compiling.

---

## High-level architecture (big picture)

- Purpose: reusable GitHub Actions workflow that builds GKI kernels for Pixel 8 family with multiple KernelSU variants and packages AnyKernel3 flashable zips.

- Key components:
  - .github/workflows/kernel-build.yml (canonical build logic + matrix)
  - .github/patches/<variant>/  (variant-specific patch sets; ordering matters)
  - kernel/ (git submodule — Google GKI tree used as build source)
  - susfs4ksu/ (git submodule — SuSFS source and fallback patches)
  - Packaging step: produces AK3 zips, Image.lz4, patch-manifest-<variant>.txt, source-manifest-<variant>.txt and build logs

- Variants: tiann, enhance, kowsu, resukisu, next. The workflow drives patch selection, fallback patch streams, and packaging per-variant.

- SuSFS patch pipeline: multi-stage — variant-specific patch → upstream susfs4ksu → Python-based fuzz/3-way merge. Patch manifest records status (applied / applied-fuzz / applied-3way / already-present / disabled / failed).

- Outputs: AK3-<kver>-<variant>-r<KSU_VERSION>.zip, Image.lz4, sha256, runtime tuner script, patch and source manifests, and build logs.

---

## Key conventions and repo-specific patterns

- Patch ordering: patch files use numeric prefixes (e.g., `10_*`, `50_*`) to enforce sequence — do not reorder or rename without understanding impact.

- Patch locations:
  - Variant-specific patches: .github/patches/<variant>/
  - Common patches: .github/patches/common/

- Workflow-control knobs (inputs to workflows / useful for dispatch):
  - `tuning_profile` (balanced|performance|battery)
  - `lto_mode` (thin|full|none)
  - `governor_mode` (dynasched|stock_schedutil)
  - `kerneltoast_patch_policy` (strict|best_effort|off)
  - `dirty_build`, `force_clean_build`, `dry_run_only`, `include_runtime_tuner`

- Source pin overrides (workflow inputs): `kernel_ref`, `susfs_ref`, `tiann_ref`, `kowsu_ref`, `resukisu_ref`, `next_ref` — the workflow is written to accept pins for reproducible runs.

- Artifact naming is stable and relied upon by release/packaging steps. Follow the existing naming when adding tooling that consumes outputs.

- Do not commit generated ZIPs, extracted `files/` output, or build artifacts into the repo. Changes should be limited to patches and workflow logic.

- YAML style: two-space indentation; shell steps should be POSIX-friendly and fail closed on required downloads/patches.

- Commit messages: follow repo prefixes (examples) — `fix(workflow): ...`, `fix(kowsu): ...`, `feat(patches): ...`, `cleanup: ...`.

- Validation for patches:
  - Ensure patches apply cleanly against the target variant
  - Avoid masking failures with `|| true` in patch steps
  - Include Change-Id, Signed-off-by, and appropriate UPSTREAM/BACKPORT/FROMGIT/ANDROID tags when relevant (see kernel/README.md for kernel patch rules)

---

## Files / places Copilot should read before code changes

- README.md (root) — project overview, knobs, outputs
- .github/workflows/kernel-build.yml — canonical automation
- AGENTS.md — repository guidelines and commands (contains quick commands and conventions)
- kernel/README.md — kernel patch and submission rules
- .github/patches/<variant>/README.md — variant-specific patch notes
- .claude/ and AGENTS.md — repo contains agent spec and orchestration rules that may affect automated agents; read if planning automation changes

---

## Short note about AI/agent configurations

- This repo contains agent/assistant artifacts (AGENTS.md, .claude/*). Copilot sessions should respect any spec/workflow conventions defined there when orchestrating sub-agents or automating spec-related tasks.

---

If anything needs to be more detailed (examples of building a specific variant locally, or explicit diff/checkpatch invocations), say which area to expand and Copilot will add short, targeted examples.

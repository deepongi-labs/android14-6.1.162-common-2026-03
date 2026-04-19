# Repository Guidelines

## Project Structure & Module Organization
This repo is a workflow-first kernel builder for Pixel 8 series devices. The main automation lives in `.github/workflows/kernel-build.yml`. Variant-specific patch sets live under `.github/patches/<variant>/` such as `tiann/`, `kowsu/`, `next/`, and `resukisu/`. External sources are tracked as submodules: `kernel/` for the Google GKI tree and `susfs4ksu/` for SuSFS. Reference bundles in `files/` and archives like `files.zip` are documentation artifacts, not active source.

## Build, Test, and Development Commands
Use GitHub Actions as the canonical build path.

- `git submodule update --init --recursive` fetches `kernel/` and `susfs4ksu/`.
- `git diff --check` catches whitespace and patch formatting issues before commit.
- `git status --short` verifies only intended files changed.
- `cd kernel && make O=out gki_defconfig` generates the base kernel config locally.
- `cd kernel && make -j"$(nproc)" LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld O=out CC="ccache clang"` mirrors the workflow build step.

When editing workflow logic, inspect `.github/workflows/kernel-build.yml` and keep local commands aligned with its toolchain and environment assumptions.

## Coding Style & Naming Conventions
YAML uses two-space indentation. Keep shell in workflow steps POSIX-friendly and fail closed on required downloads or patches. Patch files follow numeric ordering prefixes such as `10_enable_susfs_for_ksu.patch` and `50_add_susfs_in_gki-android14-6.1.patch`; preserve that sequencing. Prefer lowercase, hyphenated filenames for docs and workflow assets. Avoid committing generated ZIPs, tarballs, or extracted `files/` output unless the change explicitly updates release artifacts.

## Testing Guidelines
There is no separate unit test suite here; validation is build-oriented. For workflow changes, run `git diff --check` and review the affected YAML carefully. For patch changes, ensure the patch applies cleanly against the target variant and does not rely on `|| true` masking failures. If you touch kernel build logic, note the exact variant tested and whether SuSFS was enabled.

## Commit & Pull Request Guidelines
Follow the existing history: short imperative subjects with prefixes like `fix(workflow): ...`, `fix(kowsu): ...`, `feat(patches): ...`, and `cleanup: ...`. Keep commits scoped to one concern. PRs should describe the affected variant(s), note workflow or patch risks, link related issues if any, and include build evidence for nontrivial changes such as a successful Actions run or the exact local make command used.

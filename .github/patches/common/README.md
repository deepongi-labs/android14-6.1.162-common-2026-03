# Common Patches

Place patches here that should be applied to **ALL** KernelSU variants.

## Naming Convention

```
XX_short-description.patch
```

- `XX` = Order number (00-99)
- Patches are applied in alphabetical order
- Use lowercase with hyphens

## Examples

- `01_fix-clidr-uninitialized.patch`
- `02_fix-memory-leak.patch`
- `10_add-custom-governor.patch`

## Currently Fetched Remotely

The following patches are fetched at build time (no need to add here):

1. `fix-clidr-uninitialized.patch` - Essential ARM64 fix
2. `fix_proc_base.patch` - SuSFS related (only when SuSFS enabled)

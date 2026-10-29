# Snowflake Warehouse Administration Modules

Reusable Terraform modules for Snowflake administration and governance. Each module lives in its own folder, has its own README, and is versioned on its own.

## Modules

| Module | What it does | Current tag | Docs |
|---|---|---|---|
| [backfill](./backfill/README.md) | Backfill columns in a table one chunk at a time: control table, run log, status view, lifecycle procedures, one task per backfill, failure alerts | `backfill-v1.1.0` | [README](./backfill/README.md) |
| [tagging](./tagging/README.md) | Apply Snowflake tags to table columns (PHI, PII, PCI classifications) | `main` (untagged) | [README](./tagging/README.md) |

## Using a module

Point `source` at the repo, then `//<module folder>`, then the tag:

```hcl
module "example" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//<module>?ref=<module>-vX.Y.Z"
  # module inputs...
}
```

- **Before `//`**: the repo Terraform downloads.
- **After `//`**: the folder used as the module. Only that folder is loaded.
- **`?ref=`**: the tag. Pin a tag, never `main` — a change merged to `main` reaches every caller on its next plan.

For local work, point `source` at the folder: `../SnowflakeWHAdministration-Modules/<module>`.

## Versioning

Tags are per module: `<module>-v<MAJOR>.<MINOR>.<PATCH>` (e.g. `backfill-v1.0.0`, `tagging-v1.0.0`). A tag snapshots the whole repo, but a caller only loads its own folder, so releasing one module never changes another module's callers. Upgrading is a ref bump in the caller's PR.

Release: merge to `main`, then `git tag <module>-vX.Y.Z <commit>` and `git push origin <module>-vX.Y.Z`, and update the **Current tag** column above.

This repo holds source only. There is no CI here; plan and apply run in each calling project's CI.

## Adding a module

1. Create a lowercase folder (hyphens for multi-word names, e.g. `warehouse-sizing`).
2. Include `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`, and `examples/` with at least one working example.
3. Start the module README with a one-line purpose and a link back to this page.
4. Add a row to the **Modules** table above.
5. Tag the first release `<module>-v1.0.0`.

## Repository structure

```
SnowflakeWHAdministration-Modules/
├── README.md        # This page: module table of contents
├── backfill/        # Chunked, resumable column backfills
│   ├── README.md
│   └── examples/test-backfill/
└── tagging/         # Column tag associations
    └── README.md
```

## License

Internal use only.

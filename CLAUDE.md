# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a collection of reusable Terraform modules for Snowflake warehouse administration. The repository follows a monorepo structure where each module resides in its own subdirectory.

### Current Modules

- **tagging/** - Manages Snowflake column tag associations. Allows consumers to pass in a list of column tagging configurations and automatically creates `snowflake_tag_association` resources for each column.

## Architecture Pattern

The module uses a list-to-map conversion pattern to enable dynamic resource creation:

1. **Input**: `column_tag_associations` variable (list of objects) containing:
   - `tag_id`: The Snowflake tag ID to apply (required)
   - `tag_value`: The value for the tag (optional - uses Snowflake's default if null)
   - `table_fully_qualified_name`: Full table identifier (required)
   - `column`: Column name to tag (required)

2. **Conversion**: The list is transformed into a map using a `for` expression in locals:
   ```hcl
   map_tag_assoc = {
     for idx, column_assoc in var.column_tag_associations :
     "${column_assoc.table_fully_qualified_name}_${column_assoc.column}" => column_assoc
   }
   ```
   The composite key (`table_fqn_column`) ensures uniqueness for `for_each`.

3. **Application**: The `snowflake_tag_association` resource uses `for_each` with the map to create one association per column.

## Repository Structure

This is a monorepo containing multiple Terraform modules. Each module is in its own subdirectory:

```
SnowflakeWHAdministration-Modules/
├── tagging/              # Column tag association module
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── README.md
│   └── examples/
│       └── phi-tagging/
├── README.md            # Root README listing all modules
└── CLAUDE.md           # This file
```

Each module follows standard Terraform module conventions:
- Core module files: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`
- Examples in `examples/` subdirectory
- Module-specific documentation in module's README.md

### Adding New Modules

When adding a new module:
1. Create a new subdirectory with a descriptive name
2. Include all standard module files (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`)
3. Add at least one example in the module's `examples/` subdirectory
4. Update the root `README.md` with the new module information
5. Update this `CLAUDE.md` with any relevant architectural patterns

## Terraform Commands

### Validate and Format
```bash
terraform fmt -recursive    # Format all .tf files
terraform validate          # Validate configuration syntax
```

### Planning and Applying
```bash
terraform init              # Initialize providers and modules
terraform plan              # Preview changes
terraform apply             # Apply changes (requires user confirmation per global CLAUDE.md rules)
```

### Working with Modules
When referencing modules from a Git repository, use the double-slash (`//`) syntax to specify the subdirectory:
```hcl
module "column_tags" {
  source = "github.com/your-org/SnowflakeWHAdministration-Modules//tagging"

  column_tag_associations = [
    {
      tag_id               = "PHI"
      tag_value            = "TRUE"
      table_fully_qualified_name = "DATABASE.SCHEMA.TABLE"
      column               = "COLUMN_NAME"
    }
  ]
}
```

For local development:
```hcl
module "column_tags" {
  source = "../path/to/SnowflakeWHAdministration-Modules/tagging"

  column_tag_associations = [...]
}
```

## Key Considerations

- **Terraform Version**: Requires Terraform >= 1.3 due to use of `optional()` type constraint for `tag_value`.
- **Optional tag_value**: The `tag_value` field is optional. If omitted or set to null, the Snowflake provider will use its default value.
- **Snowflake Provider**: This module depends on the Snowflake Terraform provider >= 0.80.0.
- **Object Identifiers**: The module constructs full column identifiers as `{table_fully_qualified_name}.{column}` for the `object_identifiers` parameter.
- **Uniqueness**: The map key pattern must guarantee uniqueness across all column associations to prevent Terraform `for_each` collisions.

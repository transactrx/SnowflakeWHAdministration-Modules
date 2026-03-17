# Snowflake Column Tag Association Module

A Terraform module for managing Snowflake column tag associations. This module allows you to apply tags to specific columns across multiple tables in a declarative way.

## Features

- Apply tags to multiple columns across multiple tables
- Dynamic resource creation using `for_each`
- Automatic handling of column identifier construction
- Support for any Snowflake tag type

## Usage

```hcl
module "column_tags" {
  source = "path/to/SnowflakeWHAdministration-Modules"

  column_tag_associations = [
    {
      tag_id                     = "PHI"
      tag_value                  = "TRUE"
      table_fully_qualified_name = "DATABASE.SCHEMA.TABLE"
      column                     = "FIRST_NAME"
    },
    {
      tag_id                     = "PHI"
      tag_value                  = "TRUE"
      table_fully_qualified_name = "DATABASE.SCHEMA.TABLE"
      column                     = "LAST_NAME"
    },
    {
      tag_id                     = "PHI"
      tag_value                  = "MEDIUM"
      table_fully_qualified_name = "DATABASE.SCHEMA.ANOTHER_TABLE"
      column                     = "EMAIL"
    },
    {
      # tag_value is optional - omitting it will use Snowflake's default
      tag_id                     = "PHI"
      table_fully_qualified_name = "DATABASE.SCHEMA.ANOTHER_TABLE"
      column                     = "SSN"
    }
  ]
}
```

## Inputs

| Name | Description | Type | Required |
|------|-------------|------|----------|
| column_tag_associations | List of column tag associations to create. `tag_value` is optional. | `list(object({tag_id=string, tag_value=optional(string), table_fully_qualified_name=string, column=string}))` | yes |

## Outputs

| Name | Description |
|------|-------------|
| tag_associations | Map of created tag associations with their identifiers |
| tag_association_count | Number of tag associations created |

## Examples

See the [examples](./examples) directory for complete usage examples:

- [phi-tagging](./examples/phi-tagging) - Tagging PHI columns in a test table

## Requirements

- Terraform >= 1.3
- Snowflake provider >= 0.80.0

## License

Internal use only.

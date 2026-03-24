# Snowflake Column Tag Association Module

A Terraform module for managing Snowflake column tag associations with a simplified interface and built-in validation. Apply PHI tags to table columns with minimal code and automatic validation of tag values.

## Features

- **Simplified Interface**: Map-based configuration (12 lines vs 80+ lines)
- **Built-in Validation**: Automatic validation of PHI tag values and column names
- **Clear Error Messages**: Specific guidance when validation fails
- **Type Safety**: Compile-time validation prevents runtime errors

## Usage

### Basic Example

```hcl
module "tag_phi_columns" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//tagging?ref=main"

  tag_id                     = local.tag_id_phi
  table_fully_qualified_name = snowflake_table.CUSTOMERS.fully_qualified_name

  column_tag_values = {
    "FIRST_NAME"    = "NAME"
    "LAST_NAME"     = "NAME"
    "EMAIL_ADDRESS" = "EMAIL"
    "PHONE_NUMBER"  = "PHONE"
    "SSN"           = "SSN"
    "DATE_OF_BIRTH" = "DOB"
    "HOME_ADDRESS"  = "ADDRESS"
    "ZIP_CODE"      = "ZIP"
  }
}
```

### Real-World Example

```hcl
module "tag_trx_claims_phi" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//tagging?ref=main"

  tag_id                     = local.tag_id_phi
  table_fully_qualified_name = snowflake_table.TRX_CLAIMS.fully_qualified_name

  column_tag_values = {
    "DATE_OF_BIRTH"  = "DOB"
    "PROVIDER_FIRST" = "NAME"
    "PROVIDER_LAST"  = "NAME"
    "SITE_ADDRESS1"  = "ADDRESS"
    "SITE_ADDRESS2"  = "ADDRESS"
    "SITE_CITY"      = "TRUE"
    "SITE_STATE"     = "TRUE"
    "SITE_ZIP"       = "ZIP"
    "PATIENT_ID"     = "ACCOUNT"
    "RX_NUMBER"      = "LICENSE"
    "NDC"            = "LICENSE"
    "PRODUCT"        = "TRUE"
  }
}
```

## Valid PHI Tag Values

The module validates tag values against this list of PHI masking patterns:

| Tag Value | Masking Pattern | Use Case |
|-----------|----------------|----------|
| `EMAIL` | `***@***.***` | Email addresses |
| `PHONE` | `***-***-****` | Phone numbers |
| `SSN` | `***-**-****` | Social Security Numbers |
| `NAME` | First char + asterisks | First/last names |
| `ADDRESS` | `*** *** *** ***` | Street addresses |
| `DOB` | `YYYY-**-**` | Dates of birth |
| `CCN` | `****-****-****-1234` | Credit card numbers |
| `ACCOUNT` | `******1234` | Account numbers |
| `LICENSE` | `***MASKED***` | License numbers |
| `ZIP` | `123**` | ZIP codes |
| `IP_ADDRESS` | `192.*.*.*` | IP addresses |
| `TRUE` | `***MASKED***` | Generic PHI masking |

## Inputs

| Name | Description | Type | Required |
|------|-------------|------|----------|
| `tag_id` | Tag ID to apply to columns (e.g., local.tag_id_phi) | `string` | yes |
| `table_fully_qualified_name` | Fully qualified table name (DATABASE.SCHEMA.TABLE) | `string` | yes |
| `column_tag_values` | Map of column names to tag values | `map(string)` | yes |

### Validation Rules

#### Column Names
- Must be uppercase with underscores
- Must start with a letter or underscore
- Valid: `FIRST_NAME`, `DATE_OF_BIRTH`, `_INTERNAL_ID`
- Invalid: `first_name`, `123_ID`, `First-Name`

#### Tag Values
- Must be one of the valid PHI values listed above
- Case-sensitive (must be uppercase)
- Empty map not allowed (must tag at least one column)

## Outputs

| Name | Description |
|------|-------------|
| `tagged_columns` | Map of columns that were tagged with their PHI values |
| `table_name` | Fully qualified name of the table that was tagged |
| `tag_id` | Tag ID that was applied |
| `associations_created` | Number of column tag associations created |
| `association_keys` | List of association keys created (for debugging) |

## Error Messages

### Invalid Tag Value

```
Error: Invalid tag value(s) found: EMAIL_ADDRESS='EMAIL_ADDR'

Valid PHI masking values are:
- EMAIL (masks as ***@***.***),
- PHONE (masks as ***-***-****)
- SSN (masks as ***-**-****)
...
```

### Invalid Column Name

```
Error: Column names must be uppercase with underscores (e.g., FIRST_NAME, DATE_OF_BIRTH).
```

### Empty Column Map

```
Error: Must specify at least one column to tag.
```

## Migration Guide

### Old Interface (80+ lines)

```hcl
module "tag_phi" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//tagging?ref=main"

  column_tag_associations = [
    {
      tag_id                     = local.tag_id_phi
      tag_value                  = "NAME"
      table_fully_qualified_name = snowflake_table.CUSTOMERS.fully_qualified_name
      column                     = "FIRST_NAME"
    },
    {
      tag_id                     = local.tag_id_phi
      tag_value                  = "NAME"
      table_fully_qualified_name = snowflake_table.CUSTOMERS.fully_qualified_name
      column                     = "LAST_NAME"
    },
    # ... more repetitive blocks
  ]
}
```

### New Interface (12 lines)

```hcl
module "tag_phi" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//tagging?ref=main"

  tag_id                     = local.tag_id_phi
  table_fully_qualified_name = snowflake_table.CUSTOMERS.fully_qualified_name

  column_tag_values = {
    "FIRST_NAME" = "NAME"
    "LAST_NAME"  = "NAME"
    # ... more columns
  }
}
```

### Migration Steps

1. **Extract common values**:
   - All `tag_id` values → `tag_id` variable
   - All `table_fully_qualified_name` values → `table_fully_qualified_name` variable

2. **Convert list to map**:
   - Each list entry becomes a map entry
   - Key: `column` value
   - Value: `tag_value` value

3. **Run terraform plan**:
   - Verify "No changes" (same resources created)
   - If changes appear, check for typos in column names or tag values

## Examples

See the [examples](./examples) directory for complete usage examples:

- [test_enhanced_interface.tf](./examples/test_enhanced_interface.tf) - Valid configuration demonstrating all PHI tag values
- [test_validation.tf](./examples/test_validation.tf) - Validation error scenarios

## Requirements

- Terraform >= 1.3
- Snowflake provider >= 2.14.0

## License

Internal use only.

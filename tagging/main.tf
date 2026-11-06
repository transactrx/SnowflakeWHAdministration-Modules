terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.14.0"
    }
  }
}

//----------------------------------------------------------------------------------------------------
// Enhanced Column Tag Association Module
// Applies Snowflake tags with simplified interface and built-in validation
//----------------------------------------------------------------------------------------------------

locals {
  # Create unique keys for for_each (table_column format)
  tag_associations = {
    for column_name, tag_value in var.column_tag_values :
    "${var.table_fully_qualified_name}_${column_name}" => {
      column_name = column_name
      tag_value   = tag_value
    }
  }
}

//----------------------------------------------------------------------------------------------------
// Apply Tags to Columns
//----------------------------------------------------------------------------------------------------
# tagging_enabled = false empties the set, so the next apply removes every tag this module applied.
resource "snowflake_tag_association" "column_tags" {
  for_each = var.tagging_enabled ? local.tag_associations : {}

  object_type        = "COLUMN"
  object_identifiers = ["${var.table_fully_qualified_name}.${each.value.column_name}"]
  tag_id             = var.tag_id
  tag_value          = each.value.tag_value
}

//----------------------------------------------------------------------------------------------------
// Column Tag Association Module
// Applies Snowflake tags to specified table columns
//----------------------------------------------------------------------------------------------------

locals {
  # Convert list to map with unique keys for for_each
  map_tag_assoc = {
    for idx, column_assoc in var.column_tag_associations :
    "${column_assoc.table_fully_qualified_name}_${column_assoc.column}" => column_assoc
  }
}

//----------------------------------------------------------------------------------------------------
// Apply Tags to Columns
//----------------------------------------------------------------------------------------------------
resource "snowflake_tag_association" "column_tags" {
  for_each = local.map_tag_assoc

  object_type        = "COLUMN"
  object_identifiers = ["${each.value.table_fully_qualified_name}.${each.value.column}"]
  tag_id             = each.value.tag_id
  tag_value          = each.value.tag_value
}

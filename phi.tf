locals {
 tag_id_phi = "PHI"
}


//----------------------------------------------------------------------------------------------------
// Column Tag Associations - Define columns to be tagged
//----------------------------------------------------------------------------------------------------
locals {
  # List of columns to tag with PHI
  column_tag_associations = [
    {
      tag_id               = local.tag_id_phi
      tag_value            = "TRUE"
      table_fully_qualified_name = snowflake_table.TEST_DATA_MASKING.fully_qualified_name
      column               = "FIRST"
    },
    {
      tag_id               = local.tag_id_phi
      tag_value            = "TRUE"
      table_fully_qualified_name = snowflake_table.TEST_DATA_MASKING.fully_qualified_name
      column               = "LAST"
    },
  ]

  # Convert list to map with unique keys for for_each
  map_tag_assoc = {
    for idx, column_assoc in local.column_tag_associations :
    "${column_assoc.table_fully_qualified_name}_${column_assoc.column}" => column_assoc
  }
}

//----------------------------------------------------------------------------------------------------
// Apply Tags to Columns
//----------------------------------------------------------------------------------------------------
resource "snowflake_tag_association" "column_tags" {
  depends_on = [
    snowflake_table.TEST_DATA_MASKING,
  ]
  for_each = local.map_tag_assoc

  object_type        = "COLUMN"
  object_identifiers = ["${each.value.table_fully_qualified_name}.${each.value.column}"]
  tag_id             = each.value.tag_id
  tag_value          = each.value.tag_value
}


//----------------------------------------------------------------------------------------------------
// Test Table
//----------------------------------------------------------------------------------------------------
resource "snowflake_table" "TEST_DATA_MASKING" {
  database = "CPE_DEV"
  schema   = "DATA_SCIENCE_SHARE"
  name     = "TEST_DATA_MASKING"

  comment = "TEST_DATA_MASKING"
  column {
    name = "FIRST"
    type = "STRING"
  }
  column {
    name = "LAST"
    type = "STRING"
  }
  column {
    name = "MIDDLE"
    type = "STRING"
  }

}


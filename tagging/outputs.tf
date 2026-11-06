output "tagged_columns" {
  description = "Map of columns that are tagged with their PHI values (empty when tagging_enabled = false)"
  value       = var.tagging_enabled ? var.column_tag_values : {}
}

output "table_name" {
  description = "Fully qualified name of the table that was tagged"
  value       = var.table_fully_qualified_name
}

output "tag_id" {
  description = "Tag ID that was applied"
  value       = var.tag_id
}

output "associations_created" {
  description = "Number of column tag associations applied (0 when tagging_enabled = false)"
  value       = length(snowflake_tag_association.column_tags)
}

output "association_keys" {
  description = "List of association keys applied (for debugging; empty when tagging_enabled = false)"
  value       = keys(snowflake_tag_association.column_tags)
}

output "tagging_enabled" {
  description = "Whether this module is currently applying its tags"
  value       = var.tagging_enabled
}

output "tagged_columns" {
  description = "Map of columns that were tagged with their PHI values"
  value       = var.column_tag_values
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
  description = "Number of column tag associations created"
  value       = length(var.column_tag_values)
}

output "association_keys" {
  description = "List of association keys created (for debugging)"
  value       = keys(local.tag_associations)
}

output "tag_associations" {
  description = "Map of created tag associations with their identifiers"
  value = {
    for key, assoc in snowflake_tag_association.column_tags :
    key => {
      object_identifiers = assoc.object_identifiers
      tag_id             = assoc.tag_id
      tag_value          = assoc.tag_value
    }
  }
}

output "tag_association_count" {
  description = "Number of tag associations created"
  value       = length(snowflake_tag_association.column_tags)
}

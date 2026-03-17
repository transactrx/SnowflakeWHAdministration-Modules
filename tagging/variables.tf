variable "column_tag_associations" {
  description = "List of column tag associations to create. Each entry defines a tag to apply to a specific column. tag_value is optional and will use Snowflake's default if not provided."
  type = list(object({
    tag_id                     = string
    tag_value                  = optional(string)
    table_fully_qualified_name = string
    column                     = string
  }))

  validation {
    condition     = length(var.column_tag_associations) >= 0
    error_message = "column_tag_associations must be a valid list of tag association objects."
  }
}

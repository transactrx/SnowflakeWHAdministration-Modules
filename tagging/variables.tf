variable "tag_id" {
  description = "Tag ID to apply to columns (e.g., local.tag_id_phi)"
  type        = string
}

variable "table_fully_qualified_name" {
  description = "Fully qualified table name (DATABASE.SCHEMA.TABLE)"
  type        = string
}

variable "column_tag_values" {
  description = "Map of column names to tag values (e.g., {'EMAIL_ADDRESS' = 'EMAIL', 'SSN' = 'SSN'})"
  type        = map(string)

  validation {
    condition     = length(var.column_tag_values) > 0
    error_message = "Must specify at least one column to tag."
  }

  validation {
    condition = alltrue([
      for tag_value in values(var.column_tag_values) :
      contains([
        "EMAIL",
        "PHONE",
        "SSN",
        "NAME",
        "ADDRESS",
        "DOB",
        "CCN",
        "ACCOUNT",
        "LICENSE",
        "ZIP",
        "IP_ADDRESS",
        "TRUE"
      ], tag_value)
    ])
    error_message = <<-EOT
      Invalid tag value(s) found: ${join(", ", [for k, v in var.column_tag_values : "${k}='${v}'" if !contains(["EMAIL", "PHONE", "SSN", "NAME", "ADDRESS", "DOB", "CCN", "ACCOUNT", "LICENSE", "ZIP", "IP_ADDRESS", "TRUE"], v)])}

      Valid PHI masking values are:
      - EMAIL (masks as ***@***.***),
      - PHONE (masks as ***-***-****)
      - SSN (masks as ***-**-****)
      - NAME (masks as first char + asterisks)
      - ADDRESS (masks as *** *** *** ***)
      - DOB (masks as YYYY-**-**)
      - CCN (masks as ****-****-****-1234)
      - ACCOUNT (masks as ******1234)
      - LICENSE (masks as ***MASKED***)
      - ZIP (masks as 123**)
      - IP_ADDRESS (masks as 192.*.*.*)
      - TRUE (generic mask as ***MASKED***)
    EOT
  }

  validation {
    condition = alltrue([
      for column_name in keys(var.column_tag_values) :
      can(regex("^[A-Z_][A-Z0-9_]*$", column_name))
    ])
    error_message = "Column names must be uppercase with underscores (e.g., FIRST_NAME, DATE_OF_BIRTH)."
  }
}

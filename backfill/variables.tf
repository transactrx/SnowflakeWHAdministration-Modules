variable "database" {
  description = "Database and schema the framework is created in. The caller creates them first."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.database))
    error_message = "database must be an unquoted identifier (letters, digits, underscore)."
  }
}

variable "schema" {
  description = "Database and schema the framework is created in. The caller creates them first."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.schema))
    error_message = "schema must be an unquoted identifier (letters, digits, underscore)."
  }
}

variable "notification_integration" {
  description = "Optional notification integration (e.g. SNS_NOTIFICATION) set as ERROR_INTEGRATION on every backfill task. Null = no failure notifications. The owner role (SYSADMIN) needs USAGE on it."
  type        = string
  default     = null

  validation {
    condition     = var.notification_integration == null || can(regex("^[A-Za-z0-9_]+$", var.notification_integration))
    error_message = "notification_integration must be null or an unquoted identifier."
  }
}

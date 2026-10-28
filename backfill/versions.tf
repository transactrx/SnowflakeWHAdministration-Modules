terraform {
  required_version = ">= 1.3"

  required_providers {
    snowflake = {
      source = "snowflakedb/snowflake"
      # Callers pin ~> 2.21.0 (SnowflakeWHAdministration, ras-snowflake-admin-*) and ~> 2.22.0
      # (ras-datawarehouse-*); the module must init under both.
      version = ">= 2.21.0, < 3.0.0"
    }
  }
}

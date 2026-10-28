//----------------------------------------------------------------------------------------------------
// Test backfill: the framework plus a small target table, a "fail on" settings table and a
// contract-correct test worker. Drive it with test.sql to prove the framework end to end
// (forced failure, resume, skip, re-run, completion).
//----------------------------------------------------------------------------------------------------

terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.21.0, < 3.0.0"
    }
  }
}

provider "snowflake" {
  role = "SYSADMIN"
  preview_features_enabled = [
    "snowflake_procedure_sql_resource",
    "snowflake_table_resource",
  ]
}

variable "database" {
  description = "Test database. The caller creates it first."
  type        = string
}

variable "schema" {
  description = "Test schema. The caller creates it first."
  type        = string
}

variable "notification_integration" {
  description = "Optional notification integration for failure alerts (e.g. SNS_NOTIFICATION)."
  type        = string
  default     = null
}

module "backfill" {
  source = "../.."
  # From another repo:
  # source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//backfill?ref=backfill-v1.0.0"

  database                 = var.database
  schema                   = var.schema
  notification_integration = var.notification_integration
}

//----------------------------------------------------------------------------------------------------
// Target table. SOURCE_VALUE stands in for the source of truth; BACKFILLED_VALUE is the "new column"
// the backfill fills. TASK_META carries the row-level lineage stamps.
//----------------------------------------------------------------------------------------------------
resource "snowflake_table" "target" {
  database = var.database
  schema   = var.schema
  name     = "BACKFILL_TEST_TARGET"
  comment  = "Backfill framework test target."

  column {
    name = "ID"
    type = "NUMBER(38,0)"
  }
  column {
    name = "EVENT_TS"
    type = "TIMESTAMP_NTZ(9)"
  }
  column {
    name = "SOURCE_VALUE"
    type = "VARCHAR(100)"
  }
  column {
    name = "BACKFILLED_VALUE"
    type = "VARCHAR(100)"
  }
  column {
    name = "TASK_META"
    type = "ARRAY"
  }
}

//----------------------------------------------------------------------------------------------------
// One-row switch: the test worker raises when a chunk starts at FAIL_ON_CHUNK_START.
//----------------------------------------------------------------------------------------------------
resource "snowflake_table" "settings" {
  database = var.database
  schema   = var.schema
  name     = "BACKFILL_TEST_SETTINGS"
  comment  = "Backfill framework test: forced-failure switch."

  column {
    name = "FAIL_ON_CHUNK_START"
    type = "TIMESTAMP_NTZ(9)"
  }
}

//----------------------------------------------------------------------------------------------------
// Test worker, written to the contract:
//   (P_START, P_END exclusive, P_META) in, rows affected out; raises on failure with no data in the
//   message; update-only; NULL guard; re-run safe (the NULL guard also prevents a second TASK_META
//   stamp); prepends P_META, keeping at most 10 entries.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "test_worker" {
  database    = var.database
  schema      = var.schema
  name        = "BACKFILL_TEST_WORKER"
  comment     = "Backfill framework test worker."
  return_type = "NUMBER"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_START"
    arg_data_type = "TIMESTAMP_NTZ"
  }
  arguments {
    arg_name      = "P_END"
    arg_data_type = "TIMESTAMP_NTZ"
  }
  arguments {
    arg_name      = "P_META"
    arg_data_type = "OBJECT"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_fail_on    TIMESTAMP_NTZ;
      forced_fail  EXCEPTION (-20100, 'BACKFILL_TEST_WORKER: forced failure (BACKFILL_TEST_SETTINGS).');
  BEGIN
      SELECT MAX(FAIL_ON_CHUNK_START) INTO :v_fail_on
        FROM ${var.database}.${var.schema}.${snowflake_table.settings.name};
      IF (v_fail_on IS NOT NULL AND v_fail_on = P_START) THEN
          RAISE forced_fail;
      END IF;

      UPDATE ${var.database}.${var.schema}.${snowflake_table.target.name} t
         SET BACKFILLED_VALUE = UPPER(t.SOURCE_VALUE),
             TASK_META        = ARRAY_SLICE(ARRAY_PREPEND(COALESCE(t.TASK_META, ARRAY_CONSTRUCT()), :P_META), 0, 10)
       WHERE t.EVENT_TS >= :P_START
         AND t.EVENT_TS <  :P_END
         AND t.BACKFILLED_VALUE IS NULL;

      RETURN SQLROWCOUNT;
  END;
  EOT
}

output "framework" {
  value = module.backfill
}

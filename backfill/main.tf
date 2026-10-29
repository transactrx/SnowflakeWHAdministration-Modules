//----------------------------------------------------------------------------------------------------
// Backfill Framework
// Control table, run log, status view and lifecycle procedures for chunked, resumable backfills.
// Per-backfill tasks are NOT Terraform resources: START_BACKFILL creates BACKFILL_TASK_<name> at
// runtime and COMPLETE / CANCEL drop it. See README.md for the worker contract and usage.
//----------------------------------------------------------------------------------------------------

locals {
  db     = upper(var.database)
  schema = upper(var.schema)
  fq     = "${local.db}.${local.schema}"

  control_table = "${local.fq}.BACKFILL_CONTROL"
  run_log_table = "${local.fq}.BACKFILL_RUN_LOG"
  task_prefix   = "BACKFILL_TASK_"

  # Appended to CREATE TASK in START_BACKFILL; empty when no integration is configured.
  error_integration_clause = var.notification_integration == null ? "" : "ERROR_INTEGRATION = ${upper(var.notification_integration)}"

  # States
  # Backfill: REGISTERED -> ACTIVE <-> PAUSED, ACTIVE -> FAILED -> ACTIVE, ACTIVE -> COMPLETE, any open -> CANCELLED
  # Chunk:    STARTED -> SUCCEEDED | FAILED | TIMED_OUT, or SKIPPED (written by RESUME_BACKFILL)
  open_states_sql = "'REGISTERED','ACTIVE','PAUSED','FAILED'"
}

//----------------------------------------------------------------------------------------------------
// Control table: one row per backfill. Permanent record; never truncated.
//----------------------------------------------------------------------------------------------------
resource "snowflake_table" "control" {
  database = local.db
  schema   = local.schema
  name     = "BACKFILL_CONTROL"
  comment  = "Backfill framework: one row per backfill. Managed by Terraform (SnowflakeWHAdministration-Modules//backfill)."

  column {
    name     = "BACKFILL_ID"
    type     = "VARCHAR(36)"
    nullable = false
    comment  = "UUID. Used as RUN_GROUP_ID in the TASK_META stamp."
  }
  column {
    name     = "BACKFILL_NAME"
    type     = "VARCHAR(200)"
    nullable = false
    comment  = "Readable name, unique forever. Handle for every lifecycle call."
  }
  column {
    name     = "TARGET_TABLE"
    type     = "VARCHAR(400)"
    nullable = false
    comment  = "DB.SCHEMA.TABLE being backfilled."
  }
  column {
    name     = "WORKER_PROCEDURE"
    type     = "VARCHAR(400)"
    nullable = false
    comment  = "DB.SCHEMA.PROCEDURE(P_START TIMESTAMP_NTZ, P_END TIMESTAMP_NTZ, P_META OBJECT)."
  }
  column {
    name     = "START_TS"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = false
    comment  = "First chunk start (inclusive)."
  }
  column {
    name    = "END_TS"
    type    = "TIMESTAMP_NTZ(9)"
    comment = "Range end (exclusive). NULL = now: completes after the chunk containing the current time."
  }
  column {
    name     = "CHUNK_SIZE"
    type     = "NUMBER(38,0)"
    nullable = false
  }
  column {
    name     = "CHUNK_UNIT"
    type     = "VARCHAR(10)"
    nullable = false
    comment  = "HOUR or DAY."
  }
  column {
    name    = "WAREHOUSE"
    type    = "VARCHAR(200)"
    comment = "Warehouse for the task. NULL = serverless."
  }
  column {
    name     = "TIME_LIMIT_MINUTES"
    type     = "NUMBER(38,0)"
    nullable = false
    comment  = "Task run time limit (USER_TASK_TIMEOUT_MS)."
  }
  column {
    name     = "CURSOR_TS"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = false
    comment  = "Start of the next chunk to process."
  }
  column {
    name     = "STATE"
    type     = "VARCHAR(20)"
    nullable = false
    comment  = "REGISTERED | ACTIVE | PAUSED | FAILED | COMPLETE | CANCELLED."
  }
  column {
    name     = "ATTEMPTS"
    type     = "NUMBER(38,0)"
    nullable = false
    comment  = "Attempts on the chunk at CURSOR_TS. Reset when the cursor advances."
  }
  column {
    name    = "LAST_ERROR"
    type    = "VARCHAR(2000)"
    comment = "Safe fields only: SQLCODE, SQLSTATE, query id, chunk window. Never Snowflake error text."
  }
  column {
    name     = "TOTAL_ROWS"
    type     = "NUMBER(38,0)"
    nullable = false
  }
  column {
    name     = "CHUNKS_DONE"
    type     = "NUMBER(38,0)"
    nullable = false
    comment  = "Chunks SUCCEEDED or SKIPPED."
  }
  column {
    name     = "TASK_NAME"
    type     = "VARCHAR(400)"
    nullable = false
    comment  = "Fully qualified BACKFILL_TASK_<name>. Exists only while the backfill is open and started."
  }
  column {
    name     = "REASON"
    type     = "VARCHAR(2000)"
    nullable = false
    comment  = "Why / ticket reference. No PHI."
  }
  column {
    name     = "REGISTERED_BY"
    type     = "VARCHAR(200)"
    nullable = false
  }
  column {
    name     = "REGISTERED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = false
  }
  column {
    name = "STARTED_AT"
    type = "TIMESTAMP_LTZ(9)"
  }
  column {
    name = "FINISHED_AT"
    type = "TIMESTAMP_LTZ(9)"
  }
  column {
    name     = "UPDATED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = false
  }
}

//----------------------------------------------------------------------------------------------------
// Run log: one row per chunk attempt (plus SKIPPED rows). Permanent record. No PHI in any column.
//----------------------------------------------------------------------------------------------------
resource "snowflake_table" "run_log" {
  database = local.db
  schema   = local.schema
  name     = "BACKFILL_RUN_LOG"
  comment  = "Backfill framework: one row per chunk attempt. Managed by Terraform (SnowflakeWHAdministration-Modules//backfill)."

  column {
    name     = "RUN_ID"
    type     = "VARCHAR(36)"
    nullable = false
  }
  column {
    name     = "BACKFILL_ID"
    type     = "VARCHAR(36)"
    nullable = false
  }
  column {
    name     = "BACKFILL_NAME"
    type     = "VARCHAR(200)"
    nullable = false
  }
  column {
    name     = "CHUNK_START"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = false
  }
  column {
    name     = "CHUNK_END"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = false
  }
  column {
    name     = "ATTEMPT"
    type     = "NUMBER(38,0)"
    nullable = false
  }
  column {
    name     = "STATE"
    type     = "VARCHAR(20)"
    nullable = false
    comment  = "STARTED | SUCCEEDED | FAILED | TIMED_OUT | SKIPPED."
  }
  column {
    name    = "ROWS_AFFECTED"
    type    = "NUMBER(38,0)"
    comment = "Value returned by the worker."
  }
  column {
    name    = "QUERY_ID"
    type    = "VARCHAR(100)"
    comment = "Worker CALL query id (success) or last query id seen by the handler (failure). Read the full error in query history."
  }
  column {
    name = "SQLCODE"
    type = "NUMBER(38,0)"
  }
  column {
    name = "SQLSTATE"
    type = "VARCHAR(10)"
  }
  column {
    name    = "NOTE"
    type    = "VARCHAR(2000)"
    comment = "Framework message, or the skip reason. No PHI."
  }
  column {
    name     = "ACTED_BY"
    type     = "VARCHAR(200)"
    nullable = false
    comment  = "Task name for task runs; user for SKIPPED rows."
  }
  column {
    name     = "STARTED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = false
  }
  column {
    name = "FINISHED_AT"
    type = "TIMESTAMP_LTZ(9)"
  }
  column {
    name = "DURATION_SECONDS"
    type = "NUMBER(38,3)"
  }
  column {
    name    = "WORKER_HASH"
    type    = "VARCHAR(12)"
    comment = "First 12 hex chars of SHA-256 over the worker's GET_DDL at the start of this chunk. A change between chunks means the worker was redeployed mid-backfill."
  }
}

//----------------------------------------------------------------------------------------------------
// Status view: control row + progress + latest chunk + stall flag + worker-change flag.
// STALLED = ACTIVE with a chunk still STARTED past its time limit (the run was killed and the task
// auto-suspended). Recover with RESUME_BACKFILL, which marks that chunk TIMED_OUT and retries it.
// WORKER_CHANGED = the latest chunk ran a different worker definition than the first chunk.
//----------------------------------------------------------------------------------------------------
resource "snowflake_view" "status" {
  database = local.db
  schema   = local.schema
  name     = "BACKFILL_STATUS"
  comment  = "Backfill framework: progress per backfill. Managed by Terraform (SnowflakeWHAdministration-Modules//backfill)."

  statement = <<-SQL
    WITH latest AS (
        SELECT *
        FROM ${local.run_log_table}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY BACKFILL_ID ORDER BY STARTED_AT DESC) = 1
    ),
    worker AS (
        SELECT BACKFILL_ID,
               MIN_BY(WORKER_HASH, STARTED_AT) AS FIRST_WORKER_HASH,
               MAX_BY(WORKER_HASH, STARTED_AT) AS LAST_WORKER_HASH
        FROM ${local.run_log_table}
        WHERE WORKER_HASH IS NOT NULL
        GROUP BY BACKFILL_ID
    )
    SELECT
        c.BACKFILL_NAME,
        c.STATE,
        c.TARGET_TABLE,
        c.WORKER_PROCEDURE,
        c.START_TS,
        c.END_TS,
        IFF(c.END_TS IS NULL, 'NOW', TO_VARCHAR(c.END_TS)) AS END_DISPLAY,
        c.CHUNK_SIZE || ' ' || c.CHUNK_UNIT AS CHUNK,
        c.CURSOR_TS,
        ROUND(100 * LEAST(1, GREATEST(0,
            DATEDIFF('second', c.START_TS, c.CURSOR_TS)
            / NULLIF(DATEDIFF('second', c.START_TS, COALESCE(c.END_TS, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)), 0)
        )), 1) AS PERCENT_DONE,
        c.CHUNKS_DONE,
        c.TOTAL_ROWS,
        c.ATTEMPTS,
        c.LAST_ERROR,
        l.STATE AS LAST_CHUNK_STATE,
        l.CHUNK_START AS LAST_CHUNK_START,
        l.STARTED_AT AS LAST_CHUNK_STARTED_AT,
        l.DURATION_SECONDS AS LAST_CHUNK_SECONDS,
        (c.STATE = 'ACTIVE'
            AND l.STATE = 'STARTED'
            AND l.STARTED_AT < DATEADD('minute', -(c.TIME_LIMIT_MINUTES + 1), CURRENT_TIMESTAMP())) AS STALLED,
        COALESCE(w.FIRST_WORKER_HASH <> w.LAST_WORKER_HASH, FALSE) AS WORKER_CHANGED,
        w.LAST_WORKER_HASH,
        COALESCE(c.WAREHOUSE, 'SERVERLESS') AS COMPUTE,
        c.TIME_LIMIT_MINUTES,
        c.TASK_NAME,
        c.REASON,
        c.REGISTERED_BY,
        c.REGISTERED_AT,
        c.STARTED_AT,
        c.FINISHED_AT,
        c.BACKFILL_ID
    FROM ${local.control_table} c
    LEFT JOIN latest l ON l.BACKFILL_ID = c.BACKFILL_ID
    LEFT JOIN worker w ON w.BACKFILL_ID = c.BACKFILL_ID
  SQL

  depends_on = [snowflake_table.control, snowflake_table.run_log]
}

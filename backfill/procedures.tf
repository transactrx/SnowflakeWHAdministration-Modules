//----------------------------------------------------------------------------------------------------
// Lifecycle procedures. All run with OWNER's rights; the owner is the role Terraform runs as
// (SYSADMIN). Grant them to no other role: an owner's-rights START_BACKFILL can run any worker the
// owner can see.
//
// Snowflake Scripting exceptions only take a literal message, so every raised error below is a
// fixed string. Details (chunk window, SQLCODE, SQLSTATE, query id) go to BACKFILL_CONTROL /
// BACKFILL_RUN_LOG instead; that also keeps Snowflake's error text, which can quote data values,
// out of the raised message and out of the ERROR_INTEGRATION notification.
//----------------------------------------------------------------------------------------------------

//----------------------------------------------------------------------------------------------------
// REGISTER_BACKFILL: validate and record a backfill as REGISTERED. Nothing runs; no task is created.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "register_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "REGISTER_BACKFILL"
  comment     = "Backfill framework: register a backfill (state REGISTERED). Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }
  arguments {
    arg_name      = "P_TARGET_TABLE"
    arg_data_type = "VARCHAR"
  }
  arguments {
    arg_name      = "P_WORKER"
    arg_data_type = "VARCHAR"
  }
  arguments {
    arg_name      = "P_START"
    arg_data_type = "TIMESTAMP_NTZ"
  }
  arguments {
    arg_name      = "P_END"
    arg_data_type = "TIMESTAMP_NTZ"
  }
  arguments {
    arg_name      = "P_REASON"
    arg_data_type = "VARCHAR"
  }
  arguments {
    arg_name          = "P_CHUNK_SIZE"
    arg_data_type     = "NUMBER"
    arg_default_value = "1"
  }
  arguments {
    arg_name          = "P_CHUNK_UNIT"
    arg_data_type     = "VARCHAR"
    arg_default_value = "'DAY'"
  }
  arguments {
    arg_name          = "P_WAREHOUSE"
    arg_data_type     = "VARCHAR"
    arg_default_value = "NULL"
  }
  arguments {
    arg_name          = "P_TIME_LIMIT_MINUTES"
    arg_data_type     = "NUMBER"
    arg_default_value = "60"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name     VARCHAR;
      v_target   VARCHAR;
      v_worker   VARCHAR;
      v_unit     VARCHAR;
      v_wh       VARCHAR;
      v_id       VARCHAR;
      v_task     VARCHAR;
      v_n        INTEGER;
      v_sql      VARCHAR;
      bad_name      EXCEPTION (-20001, 'REGISTER_BACKFILL: name must be 1-200 letters, digits or underscores.');
      name_taken    EXCEPTION (-20002, 'REGISTER_BACKFILL: a backfill with this name already exists. Names are unique forever; pick a new one.');
      bad_target    EXCEPTION (-20003, 'REGISTER_BACKFILL: target table must be an existing DB.SCHEMA.TABLE (unquoted identifiers).');
      bad_worker    EXCEPTION (-20004, 'REGISTER_BACKFILL: worker must be an existing DB.SCHEMA.PROCEDURE(TIMESTAMP_NTZ, TIMESTAMP_NTZ, OBJECT) (unquoted identifiers).');
      bad_range     EXCEPTION (-20005, 'REGISTER_BACKFILL: start is required; end must be NULL (now) or later than start.');
      bad_chunk     EXCEPTION (-20006, 'REGISTER_BACKFILL: chunk size must be a whole number >= 1 and chunk unit HOUR or DAY.');
      bad_warehouse EXCEPTION (-20007, 'REGISTER_BACKFILL: warehouse must be NULL (serverless) or an unquoted identifier.');
      bad_limit     EXCEPTION (-20008, 'REGISTER_BACKFILL: time limit must be a whole number of minutes between 1 and 1440.');
      bad_reason    EXCEPTION (-20009, 'REGISTER_BACKFILL: reason is required.');
      table_busy    EXCEPTION (-20010, 'REGISTER_BACKFILL: the target table already has an open backfill (REGISTERED, ACTIVE, PAUSED or FAILED).');
  BEGIN
      v_name   := UPPER(TRIM(P_NAME));
      v_target := UPPER(TRIM(P_TARGET_TABLE));
      v_worker := UPPER(TRIM(P_WORKER));
      v_unit   := UPPER(TRIM(P_CHUNK_UNIT));
      v_wh     := UPPER(TRIM(P_WAREHOUSE));

      IF (v_name IS NULL OR NOT REGEXP_LIKE(v_name, '^[A-Z0-9_]{1,200}$')) THEN
          RAISE bad_name;
      END IF;
      IF (P_START IS NULL OR (P_END IS NOT NULL AND P_END <= P_START)) THEN
          RAISE bad_range;
      END IF;
      IF (P_CHUNK_SIZE IS NULL OR P_CHUNK_SIZE < 1 OR P_CHUNK_SIZE <> FLOOR(P_CHUNK_SIZE)
          OR v_unit IS NULL OR v_unit NOT IN ('HOUR', 'DAY')) THEN
          RAISE bad_chunk;
      END IF;
      IF (v_wh IS NOT NULL AND NOT REGEXP_LIKE(v_wh, '^[A-Z0-9_$]+$')) THEN
          RAISE bad_warehouse;
      END IF;
      IF (P_TIME_LIMIT_MINUTES IS NULL OR P_TIME_LIMIT_MINUTES < 1 OR P_TIME_LIMIT_MINUTES > 1440
          OR P_TIME_LIMIT_MINUTES <> FLOOR(P_TIME_LIMIT_MINUTES)) THEN
          RAISE bad_limit;
      END IF;
      IF (P_REASON IS NULL OR TRIM(P_REASON) = '') THEN
          RAISE bad_reason;
      END IF;

      -- Identifier shape first (these strings are concatenated into DDL), then existence.
      IF (v_target IS NULL OR NOT REGEXP_LIKE(v_target, '^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$')) THEN
          RAISE bad_target;
      END IF;
      BEGIN
          v_sql := 'DESCRIBE TABLE ' || v_target;
          EXECUTE IMMEDIATE :v_sql;
      EXCEPTION
          WHEN OTHER THEN RAISE bad_target;
      END;

      IF (v_worker IS NULL OR NOT REGEXP_LIKE(v_worker, '^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$')) THEN
          RAISE bad_worker;
      END IF;
      BEGIN
          v_sql := 'DESCRIBE PROCEDURE ' || v_worker || '(TIMESTAMP_NTZ, TIMESTAMP_NTZ, OBJECT)';
          EXECUTE IMMEDIATE :v_sql;
      EXCEPTION
          WHEN OTHER THEN RAISE bad_worker;
      END;

      SELECT COUNT(*) INTO :v_n FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
      IF (v_n > 0) THEN
          RAISE name_taken;
      END IF;

      v_id   := UUID_STRING();
      v_task := '${local.fq}.${local.task_prefix}' || v_name;

      -- One statement re-checks both rules, so two concurrent registrations cannot both win.
      INSERT INTO ${local.control_table} (
          BACKFILL_ID, BACKFILL_NAME, TARGET_TABLE, WORKER_PROCEDURE, START_TS, END_TS,
          CHUNK_SIZE, CHUNK_UNIT, WAREHOUSE, TIME_LIMIT_MINUTES, CURSOR_TS, STATE, ATTEMPTS,
          LAST_ERROR, TOTAL_ROWS, CHUNKS_DONE, TASK_NAME, REASON, REGISTERED_BY, REGISTERED_AT,
          STARTED_AT, FINISHED_AT, UPDATED_AT)
      SELECT
          :v_id, :v_name, :v_target, :v_worker, :P_START, :P_END,
          :P_CHUNK_SIZE, :v_unit, :v_wh, :P_TIME_LIMIT_MINUTES, :P_START, 'REGISTERED', 0,
          NULL, 0, 0, :v_task, TRIM(:P_REASON), CURRENT_USER(), CURRENT_TIMESTAMP(),
          NULL, NULL, CURRENT_TIMESTAMP()
      FROM (SELECT 1) one
      WHERE NOT EXISTS (SELECT 1 FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name)
        AND NOT EXISTS (SELECT 1 FROM ${local.control_table}
                        WHERE TARGET_TABLE = :v_target AND STATE IN (${local.open_states_sql}));
      IF (SQLROWCOUNT = 0) THEN
          SELECT COUNT(*) INTO :v_n FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
          IF (v_n > 0) THEN
              RAISE name_taken;
          END IF;
          RAISE table_busy;
      END IF;

      RETURN 'Registered ' || v_name || ' (' || v_id || '), state REGISTERED. Next: CALL ${local.fq}.START_BACKFILL(''' || v_name || ''');';
  END;
  EOT

  depends_on = [snowflake_table.control]
}

//----------------------------------------------------------------------------------------------------
// START_BACKFILL: REGISTERED -> ACTIVE. Creates and resumes BACKFILL_TASK_<name>.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "start_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "START_BACKFILL"
  comment     = "Backfill framework: create and resume the backfill's task (REGISTERED -> ACTIVE). Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name   VARCHAR;
      v_state  VARCHAR;
      v_id     VARCHAR;
      v_task   VARCHAR;
      v_wh     VARCHAR;
      v_limit  INTEGER;
      v_sql    VARCHAR;
      not_found      EXCEPTION (-20020, 'START_BACKFILL: no backfill with this name.');
      already_active EXCEPTION (-20021, 'START_BACKFILL: backfill is already running (ACTIVE).');
      use_resume     EXCEPTION (-20022, 'START_BACKFILL: backfill is PAUSED or FAILED; use RESUME_BACKFILL.');
      finished       EXCEPTION (-20023, 'START_BACKFILL: backfill is COMPLETE or CANCELLED; register a new backfill with a new name.');
  BEGIN
      v_name := UPPER(TRIM(P_NAME));

      -- The state guard: only one caller can flip REGISTERED -> ACTIVE.
      UPDATE ${local.control_table}
         SET STATE = 'ACTIVE', STARTED_AT = CURRENT_TIMESTAMP(), UPDATED_AT = CURRENT_TIMESTAMP()
       WHERE BACKFILL_NAME = :v_name AND STATE = 'REGISTERED';
      IF (SQLROWCOUNT = 0) THEN
          SELECT MAX(STATE) INTO :v_state FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
          IF (v_state IS NULL) THEN
              RAISE not_found;
          ELSEIF (v_state = 'ACTIVE') THEN
              RAISE already_active;
          ELSEIF (v_state IN ('PAUSED', 'FAILED')) THEN
              RAISE use_resume;
          ELSE
              RAISE finished;
          END IF;
      END IF;

      SELECT BACKFILL_ID, TASK_NAME, WAREHOUSE, TIME_LIMIT_MINUTES
        INTO :v_id, :v_task, :v_wh, :v_limit
        FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;

      BEGIN
          -- CREATE TASK, never CREATE OR REPLACE: an existing task means something is wrong.
          v_sql := 'CREATE TASK ' || v_task
              || IFF(v_wh IS NULL, ' USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = ''XSMALL''', ' WAREHOUSE = ' || v_wh)
              || ' SCHEDULE = ''1 MINUTE'''
              || ' USER_TASK_TIMEOUT_MS = ' || TO_VARCHAR(v_limit * 60000)
              || ' SUSPEND_TASK_AFTER_NUM_FAILURES = 1'
              || ' ${local.error_integration_clause}'
              || ' COMMENT = ''Backfill ' || v_name || ' (' || v_id || '). Created by START_BACKFILL; do not edit or drop by hand.'''
              || ' AS CALL ${local.fq}.EXECUTE_BACKFILL(''' || v_name || ''')';
          EXECUTE IMMEDIATE :v_sql;
          v_sql := 'ALTER TASK ' || v_task || ' RESUME';
          EXECUTE IMMEDIATE :v_sql;
      EXCEPTION
          WHEN OTHER THEN
              -- Undo so START can be retried once the cause (e.g. a missing grant) is fixed.
              v_sql := 'DROP TASK IF EXISTS ' || v_task;
              EXECUTE IMMEDIATE :v_sql;
              UPDATE ${local.control_table}
                 SET STATE = 'REGISTERED', STARTED_AT = NULL, UPDATED_AT = CURRENT_TIMESTAMP()
               WHERE BACKFILL_NAME = :v_name AND STATE = 'ACTIVE';
              RAISE;
      END;

      RETURN 'Started ' || v_name || ': task ' || v_task || ' runs one chunk per minute. Watch ${local.fq}.BACKFILL_STATUS.';
  END;
  EOT

  depends_on = [snowflake_table.control, snowflake_procedure_sql.execute_backfill]
}

//----------------------------------------------------------------------------------------------------
// PAUSE_BACKFILL: ACTIVE -> PAUSED. Suspends the task; a chunk already running finishes.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "pause_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "PAUSE_BACKFILL"
  comment     = "Backfill framework: suspend the backfill's task (ACTIVE -> PAUSED). Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name  VARCHAR;
      v_state VARCHAR;
      v_task  VARCHAR;
      v_sql   VARCHAR;
      not_found  EXCEPTION (-20030, 'PAUSE_BACKFILL: no backfill with this name.');
      not_active EXCEPTION (-20031, 'PAUSE_BACKFILL: only an ACTIVE backfill can be paused.');
  BEGIN
      v_name := UPPER(TRIM(P_NAME));

      UPDATE ${local.control_table}
         SET STATE = 'PAUSED', UPDATED_AT = CURRENT_TIMESTAMP()
       WHERE BACKFILL_NAME = :v_name AND STATE = 'ACTIVE';
      IF (SQLROWCOUNT = 0) THEN
          SELECT MAX(STATE) INTO :v_state FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
          IF (v_state IS NULL) THEN
              RAISE not_found;
          END IF;
          RAISE not_active;
      END IF;

      SELECT TASK_NAME INTO :v_task FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
      v_sql := 'ALTER TASK IF EXISTS ' || v_task || ' SUSPEND';
      EXECUTE IMMEDIATE :v_sql;

      RETURN 'Paused ' || v_name || '. Resume with CALL ${local.fq}.RESUME_BACKFILL(''' || v_name || ''');';
  END;
  EOT

  depends_on = [snowflake_table.control]
}

//----------------------------------------------------------------------------------------------------
// RESUME_BACKFILL: PAUSED or FAILED -> ACTIVE, and resumes the task.
//   RESUME_BACKFILL('<name>')                    retry the chunk at the cursor
//   RESUME_BACKFILL('<name>', TRUE, '<reason>')  FAILED only: record that chunk SKIPPED, move on
// A stalled ACTIVE backfill (chunk still STARTED past its time limit; the killed run suspended the
// task) is first marked TIMED_OUT / FAILED here, then resumed.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "resume_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "RESUME_BACKFILL"
  comment     = "Backfill framework: resume a PAUSED or FAILED backfill, optionally skipping the failed chunk. Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }
  arguments {
    arg_name          = "P_SKIP"
    arg_data_type     = "BOOLEAN"
    arg_default_value = "FALSE"
  }
  arguments {
    arg_name          = "P_SKIP_REASON"
    arg_data_type     = "VARCHAR"
    arg_default_value = "NULL"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name        VARCHAR;
      v_id          VARCHAR;
      v_state       VARCHAR;
      v_task        VARCHAR;
      v_cursor      TIMESTAMP_NTZ;
      v_end         TIMESTAMP_NTZ;
      v_size        INTEGER;
      v_unit        VARCHAR;
      v_limit       INTEGER;
      v_attempts    INTEGER;
      v_chunk_end   TIMESTAMP_NTZ;
      v_stalled     INTEGER;
      v_skip        BOOLEAN;
      v_sql         VARCHAR;
      not_found     EXCEPTION (-20040, 'RESUME_BACKFILL: no backfill with this name.');
      not_resumable EXCEPTION (-20041, 'RESUME_BACKFILL: only a PAUSED, FAILED or stalled ACTIVE backfill can be resumed.');
      skip_failed   EXCEPTION (-20042, 'RESUME_BACKFILL: skip is only allowed on a FAILED backfill.');
      skip_reason   EXCEPTION (-20043, 'RESUME_BACKFILL: skip requires a reason.');
      changed       EXCEPTION (-20044, 'RESUME_BACKFILL: the backfill changed state during the call; check BACKFILL_STATUS and retry.');
  BEGIN
      v_name := UPPER(TRIM(P_NAME));
      v_skip := COALESCE(P_SKIP, FALSE);

      SELECT COUNT(*) INTO :v_stalled FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
      IF (v_stalled = 0) THEN
          RAISE not_found;
      END IF;

      SELECT BACKFILL_ID, STATE, TASK_NAME, CURSOR_TS, END_TS, CHUNK_SIZE, CHUNK_UNIT, TIME_LIMIT_MINUTES, ATTEMPTS
        INTO :v_id, :v_state, :v_task, :v_cursor, :v_end, :v_size, :v_unit, :v_limit, :v_attempts
        FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;

      -- Stalled: the run was killed at the time limit, so it never recorded its own failure.
      IF (v_state = 'ACTIVE') THEN
          SELECT COUNT(*) INTO :v_stalled FROM ${local.run_log_table}
           WHERE BACKFILL_ID = :v_id AND STATE = 'STARTED'
             AND STARTED_AT < DATEADD('minute', -(:v_limit + 1), CURRENT_TIMESTAMP());
          IF (v_stalled > 0) THEN
              UPDATE ${local.run_log_table}
                 SET STATE = 'TIMED_OUT', FINISHED_AT = CURRENT_TIMESTAMP(),
                     NOTE = 'Found still STARTED by RESUME_BACKFILL at ' || TO_VARCHAR(CURRENT_TIMESTAMP()) || '; run exceeded its time limit.'
               WHERE BACKFILL_ID = :v_id AND STATE = 'STARTED';
              UPDATE ${local.control_table}
                 SET STATE = 'FAILED', UPDATED_AT = CURRENT_TIMESTAMP(),
                     LAST_ERROR = 'Chunk starting ' || TO_VARCHAR(:v_cursor) || ' timed out (run exceeded ' || :v_limit || ' minutes).'
               WHERE BACKFILL_ID = :v_id AND STATE = 'ACTIVE';
              v_state := 'FAILED';
          END IF;
      END IF;

      IF (v_state NOT IN ('PAUSED', 'FAILED')) THEN
          RAISE not_resumable;
      END IF;
      IF (v_skip AND v_state <> 'FAILED') THEN
          RAISE skip_failed;
      END IF;
      IF (v_skip AND (P_SKIP_REASON IS NULL OR TRIM(P_SKIP_REASON) = '')) THEN
          RAISE skip_reason;
      END IF;

      v_chunk_end := IFF(v_unit = 'HOUR', DATEADD('hour', v_size, v_cursor), DATEADD('day', v_size, v_cursor));
      IF (v_end IS NOT NULL AND v_chunk_end > v_end) THEN
          v_chunk_end := v_end;
      END IF;

      -- State guard: flip only if nothing changed since the read.
      UPDATE ${local.control_table}
         SET STATE       = 'ACTIVE',
             CURSOR_TS   = IFF(:v_skip, :v_chunk_end, CURSOR_TS),
             ATTEMPTS    = IFF(:v_skip, 0, ATTEMPTS),
             CHUNKS_DONE = CHUNKS_DONE + IFF(:v_skip, 1, 0),
             LAST_ERROR  = IFF(:v_skip, NULL, LAST_ERROR),
             UPDATED_AT  = CURRENT_TIMESTAMP()
       WHERE BACKFILL_ID = :v_id AND STATE = :v_state AND CURSOR_TS = :v_cursor;
      IF (SQLROWCOUNT = 0) THEN
          RAISE changed;
      END IF;

      IF (v_skip) THEN
          INSERT INTO ${local.run_log_table}
              (RUN_ID, BACKFILL_ID, BACKFILL_NAME, CHUNK_START, CHUNK_END, ATTEMPT, STATE, NOTE, ACTED_BY, STARTED_AT, FINISHED_AT)
          VALUES
              (UUID_STRING(), :v_id, :v_name, :v_cursor, :v_chunk_end, :v_attempts, 'SKIPPED',
               TRIM(:P_SKIP_REASON), CURRENT_USER(), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
      END IF;

      -- Resuming also resets the task's consecutive-failure count.
      v_sql := 'ALTER TASK ' || v_task || ' RESUME';
      EXECUTE IMMEDIATE :v_sql;

      RETURN 'Resumed ' || v_name || IFF(v_skip, ' after skipping the chunk starting ' || TO_VARCHAR(v_cursor), '; next run retries the chunk starting ' || TO_VARCHAR(v_cursor)) || '.';
  END;
  EOT

  depends_on = [snowflake_table.control, snowflake_table.run_log]
}

//----------------------------------------------------------------------------------------------------
// CANCEL_BACKFILL: any open state -> CANCELLED. Drops the task. Control and log rows stay.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "cancel_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "CANCEL_BACKFILL"
  comment     = "Backfill framework: stop a backfill for good and drop its task. Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name  VARCHAR;
      v_state VARCHAR;
      v_task  VARCHAR;
      v_sql   VARCHAR;
      not_found EXCEPTION (-20060, 'CANCEL_BACKFILL: no backfill with this name.');
      not_open  EXCEPTION (-20061, 'CANCEL_BACKFILL: backfill is already COMPLETE or CANCELLED.');
  BEGIN
      v_name := UPPER(TRIM(P_NAME));

      UPDATE ${local.control_table}
         SET STATE = 'CANCELLED', FINISHED_AT = CURRENT_TIMESTAMP(), UPDATED_AT = CURRENT_TIMESTAMP()
       WHERE BACKFILL_NAME = :v_name AND STATE IN (${local.open_states_sql});
      IF (SQLROWCOUNT = 0) THEN
          SELECT MAX(STATE) INTO :v_state FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
          IF (v_state IS NULL) THEN
              RAISE not_found;
          END IF;
          RAISE not_open;
      END IF;

      SELECT TASK_NAME INTO :v_task FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
      v_sql := 'DROP TASK IF EXISTS ' || v_task;
      EXECUTE IMMEDIATE :v_sql;

      RETURN 'Cancelled ' || v_name || '; task dropped. Control and run log rows are kept.';
  END;
  EOT

  depends_on = [snowflake_table.control]
}

//----------------------------------------------------------------------------------------------------
// EXECUTE_BACKFILL: called by BACKFILL_TASK_<name> once a minute. Processes one chunk.
//   - not ACTIVE        -> returns quietly (a quiet run counts as a success for the task)
//   - chunk still STARTED from an earlier run -> TIMED_OUT, backfill FAILED, raise
//   - range finished    -> COMPLETE, task suspended and dropped
//   - worker raises     -> chunk FAILED, backfill FAILED (both committed), raise a fixed message:
//                          the task run fails, ERROR_INTEGRATION notifies once, and
//                          SUSPEND_TASK_AFTER_NUM_FAILURES = 1 suspends the task
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "execute_backfill" {
  database    = local.db
  schema      = local.schema
  name        = "EXECUTE_BACKFILL"
  comment     = "Backfill framework: run one chunk of a backfill. Called by BACKFILL_TASK_<name>. Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  arguments {
    arg_name      = "P_NAME"
    arg_data_type = "VARCHAR"
  }

  procedure_definition = <<-EOT
  DECLARE
      v_name        VARCHAR;
      v_n           INTEGER;
      v_id          VARCHAR;
      v_state       VARCHAR;
      v_worker      VARCHAR;
      v_task        VARCHAR;
      v_cursor      TIMESTAMP_NTZ;
      v_end         TIMESTAMP_NTZ;
      v_now         TIMESTAMP_NTZ;
      v_size        INTEGER;
      v_unit        VARCHAR;
      v_attempt     INTEGER;
      v_reason      VARCHAR;
      v_reg_by      VARCHAR;
      v_chunk_end   TIMESTAMP_NTZ;
      v_run_id      VARCHAR;
      v_acted_by    VARCHAR;
      v_meta_json   VARCHAR;
      v_started     TIMESTAMP_LTZ;
      v_rows        INTEGER;
      v_qid         VARCHAR;
      v_code        INTEGER;
      v_sqlstate    VARCHAR;
      v_done        BOOLEAN DEFAULT FALSE;
      v_sql         VARCHAR;
      not_found       EXCEPTION (-20050, 'EXECUTE_BACKFILL: no backfill with this name.');
      chunk_timed_out EXCEPTION (-20051, 'EXECUTE_BACKFILL: previous chunk was still STARTED (its run exceeded the time limit). Backfill is FAILED; see BACKFILL_STATUS and BACKFILL_RUN_LOG.');
      chunk_failed    EXCEPTION (-20052, 'EXECUTE_BACKFILL: worker failed. Backfill is FAILED and its task suspended; see BACKFILL_STATUS and BACKFILL_RUN_LOG.');
  BEGIN
      v_name := UPPER(TRIM(P_NAME));

      SELECT COUNT(*) INTO :v_n FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;
      IF (v_n = 0) THEN
          RAISE not_found;
      END IF;

      SELECT BACKFILL_ID, STATE, WORKER_PROCEDURE, TASK_NAME, CURSOR_TS, END_TS, CHUNK_SIZE, CHUNK_UNIT,
             ATTEMPTS, REASON, REGISTERED_BY
        INTO :v_id, :v_state, :v_worker, :v_task, :v_cursor, :v_end, :v_size, :v_unit,
             :v_attempt, :v_reason, :v_reg_by
        FROM ${local.control_table} WHERE BACKFILL_NAME = :v_name;

      IF (v_state <> 'ACTIVE') THEN
          RETURN v_name || ' is ' || v_state || '; nothing to do.';
      END IF;

      -- Task runs never overlap, so a STARTED row at the start of a run belongs to a killed run.
      SELECT COUNT(*) INTO :v_n FROM ${local.run_log_table} WHERE BACKFILL_ID = :v_id AND STATE = 'STARTED';
      IF (v_n > 0) THEN
          UPDATE ${local.run_log_table}
             SET STATE = 'TIMED_OUT', FINISHED_AT = CURRENT_TIMESTAMP(),
                 NOTE = 'Found still STARTED at ' || TO_VARCHAR(CURRENT_TIMESTAMP()) || '; previous run exceeded its time limit.'
           WHERE BACKFILL_ID = :v_id AND STATE = 'STARTED';
          UPDATE ${local.control_table}
             SET STATE = 'FAILED', UPDATED_AT = CURRENT_TIMESTAMP(),
                 LAST_ERROR = 'Chunk starting ' || TO_VARCHAR(:v_cursor) || ' timed out (found still STARTED at ' || TO_VARCHAR(CURRENT_TIMESTAMP()) || ').'
           WHERE BACKFILL_ID = :v_id AND STATE = 'ACTIVE';
          RAISE chunk_timed_out;
      END IF;

      -- Finished? Fixed end: cursor reached END_TS (exclusive). NULL end ("now"): the chunk
      -- containing the current time has been processed.
      v_now := CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
      IF ((v_end IS NOT NULL AND v_cursor >= v_end) OR (v_end IS NULL AND v_cursor > v_now)) THEN
          v_done := TRUE;
      END IF;

      IF (NOT v_done) THEN
          v_chunk_end := IFF(v_unit = 'HOUR', DATEADD('hour', v_size, v_cursor), DATEADD('day', v_size, v_cursor));
          IF (v_end IS NOT NULL AND v_chunk_end > v_end) THEN
              v_chunk_end := v_end;
          END IF;
          v_attempt := v_attempt + 1;
          v_run_id  := UUID_STRING();
          v_started := CURRENT_TIMESTAMP();

          -- TASK_META stamp. Same six keys as ImportFromStageTable's TASK_META object, with
          -- RUN_GROUP_ID = backfill id, plus the backfill keys. Runtime info is absent when
          -- EXECUTE_BACKFILL is called by hand, so the stamp falls back to the backfill keys.
          BEGIN
              SELECT TO_JSON(OBJECT_CONSTRUCT(
                         'RUN_GROUP_ID',   :v_id,
                         'ROOT_TASK_NAME', SYSTEM$TASK_RUNTIME_INFO('CURRENT_ROOT_TASK_NAME'),
                         'ROOT_TASK_UUID', SYSTEM$TASK_RUNTIME_INFO('CURRENT_ROOT_TASK_UUID'),
                         'TASK_NAME',      SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_NAME'),
                         'SCHEDULED_TIME', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_ORIGINAL_SCHEDULED_TIMESTAMP'),
                         'RUN_TIME',       CURRENT_TIMESTAMP(),
                         'OPERATION',      'BACKFILL',
                         'BACKFILL_NAME',  :v_name,
                         'CHUNK_START',    :v_cursor,
                         'CHUNK_END',      :v_chunk_end,
                         'REASON',         :v_reason,
                         'REGISTERED_BY',  :v_reg_by)),
                     COALESCE(SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_NAME'), CURRENT_USER())
                INTO :v_meta_json, :v_acted_by;
          EXCEPTION
              WHEN OTHER THEN
                  SELECT TO_JSON(OBJECT_CONSTRUCT(
                             'RUN_GROUP_ID',  :v_id,
                             'RUN_TIME',      CURRENT_TIMESTAMP(),
                             'OPERATION',     'BACKFILL',
                             'BACKFILL_NAME', :v_name,
                             'CHUNK_START',   :v_cursor,
                             'CHUNK_END',     :v_chunk_end,
                             'REASON',        :v_reason,
                             'REGISTERED_BY', :v_reg_by)),
                         CURRENT_USER()
                    INTO :v_meta_json, :v_acted_by;
          END;

          UPDATE ${local.control_table} SET ATTEMPTS = :v_attempt, UPDATED_AT = CURRENT_TIMESTAMP() WHERE BACKFILL_ID = :v_id;
          INSERT INTO ${local.run_log_table}
              (RUN_ID, BACKFILL_ID, BACKFILL_NAME, CHUNK_START, CHUNK_END, ATTEMPT, STATE, ACTED_BY, STARTED_AT)
          VALUES
              (:v_run_id, :v_id, :v_name, :v_cursor, :v_chunk_end, :v_attempt, 'STARTED', :v_acted_by, :v_started);

          BEGIN
              v_sql := 'CALL ' || v_worker || '(?, ?, PARSE_JSON(?)::OBJECT)';
              LET rs RESULTSET := (EXECUTE IMMEDIATE :v_sql USING (v_cursor, v_chunk_end, v_meta_json));
              v_qid := SQLID;
              LET c CURSOR FOR rs;
              OPEN c;
              FETCH c INTO v_rows;
              CLOSE c;
          EXCEPTION
              WHEN OTHER THEN
                  -- Keep only safe fields. SQLERRM can quote data values; it is never stored or raised.
                  v_code     := SQLCODE;
                  v_sqlstate := SQLSTATE;
                  v_qid      := LAST_QUERY_ID();
                  UPDATE ${local.run_log_table}
                     SET STATE = 'FAILED', SQLCODE = :v_code, SQLSTATE = :v_sqlstate, QUERY_ID = :v_qid,
                         FINISHED_AT = CURRENT_TIMESTAMP(),
                         DURATION_SECONDS = DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()) / 1000,
                         NOTE = 'Worker raised. Read the full error in query history by QUERY_ID.'
                   WHERE RUN_ID = :v_run_id;
                  UPDATE ${local.control_table}
                     SET STATE = 'FAILED', UPDATED_AT = CURRENT_TIMESTAMP(),
                         LAST_ERROR = 'Chunk ' || TO_VARCHAR(:v_cursor) || ' to ' || TO_VARCHAR(:v_chunk_end)
                                   || ' failed: SQLCODE ' || COALESCE(TO_VARCHAR(:v_code), '?')
                                   || ', SQLSTATE ' || COALESCE(:v_sqlstate, '?')
                                   || ', query ' || COALESCE(:v_qid, '?') || '.'
                   WHERE BACKFILL_ID = :v_id AND STATE IN ('ACTIVE', 'PAUSED');
                  RAISE chunk_failed;
          END;

          v_rows := COALESCE(v_rows, 0);
          UPDATE ${local.run_log_table}
             SET STATE = 'SUCCEEDED', ROWS_AFFECTED = :v_rows, QUERY_ID = :v_qid,
                 FINISHED_AT = CURRENT_TIMESTAMP(),
                 DURATION_SECONDS = DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()) / 1000
           WHERE RUN_ID = :v_run_id;
          -- Cursor guard: advance only from the chunk this run processed.
          UPDATE ${local.control_table}
             SET CURSOR_TS = :v_chunk_end, ATTEMPTS = 0, TOTAL_ROWS = TOTAL_ROWS + :v_rows,
                 CHUNKS_DONE = CHUNKS_DONE + 1, LAST_ERROR = NULL, UPDATED_AT = CURRENT_TIMESTAMP()
           WHERE BACKFILL_ID = :v_id AND CURSOR_TS = :v_cursor;

          -- Finish now rather than on the next run when that was the last chunk.
          IF ((v_end IS NOT NULL AND v_chunk_end >= v_end) OR (v_end IS NULL AND v_chunk_end > v_now)) THEN
              v_done := TRUE;
          END IF;
      END IF;

      IF (v_done) THEN
          UPDATE ${local.control_table}
             SET STATE = 'COMPLETE', FINISHED_AT = CURRENT_TIMESTAMP(), UPDATED_AT = CURRENT_TIMESTAMP()
           WHERE BACKFILL_ID = :v_id AND STATE = 'ACTIVE';
          IF (SQLROWCOUNT = 1) THEN
              -- The task is dropping itself mid-run. If Snowflake refuses, the task stays
              -- suspended and CLEANUP_BACKFILL_TASKS removes it.
              BEGIN
                  v_sql := 'ALTER TASK IF EXISTS ' || v_task || ' SUSPEND';
                  EXECUTE IMMEDIATE :v_sql;
                  v_sql := 'DROP TASK IF EXISTS ' || v_task;
                  EXECUTE IMMEDIATE :v_sql;
              EXCEPTION
                  WHEN OTHER THEN NULL;
              END;
          END IF;
          RETURN v_name || ' COMPLETE.';
      END IF;

      RETURN v_name || ': chunk ' || TO_VARCHAR(v_cursor) || ' to ' || TO_VARCHAR(v_chunk_end) || ' SUCCEEDED, ' || v_rows || ' rows.';
  END;
  EOT

  depends_on = [snowflake_table.control, snowflake_table.run_log]
}

//----------------------------------------------------------------------------------------------------
// CLEANUP_BACKFILL_TASKS: drop any BACKFILL_TASK_* left behind by a COMPLETE or CANCELLED backfill
// (e.g. a task that could not drop itself). Never touches a task of an open backfill.
//----------------------------------------------------------------------------------------------------
resource "snowflake_procedure_sql" "cleanup_backfill_tasks" {
  database    = local.db
  schema      = local.schema
  name        = "CLEANUP_BACKFILL_TASKS"
  comment     = "Backfill framework: drop leftover tasks of COMPLETE or CANCELLED backfills. Managed by Terraform."
  return_type = "VARCHAR"
  execute_as  = "OWNER"

  procedure_definition = <<-EOT
  DECLARE
      v_qid     VARCHAR;
      v_dropped VARCHAR DEFAULT '';
      v_sql     VARCHAR;
      leftovers RESULTSET;
  BEGIN
      SHOW TASKS LIKE '${local.task_prefix}%' IN SCHEMA ${local.fq};
      v_qid := SQLID;

      leftovers := (
          SELECT c.TASK_NAME AS FQ_TASK
          FROM TABLE(RESULT_SCAN(:v_qid)) t
          JOIN ${local.control_table} c
            ON c.TASK_NAME = '${local.fq}.' || t."name"
          WHERE c.STATE IN ('COMPLETE', 'CANCELLED')
      );

      LET cur CURSOR FOR leftovers;
      FOR r IN cur DO
          v_sql := 'DROP TASK IF EXISTS ' || r.FQ_TASK;
          EXECUTE IMMEDIATE :v_sql;
          v_dropped := v_dropped || r.FQ_TASK || '; ';
      END FOR;

      RETURN IFF(v_dropped = '', 'No leftover backfill tasks.', 'Dropped: ' || v_dropped);
  END;
  EOT

  depends_on = [snowflake_table.control]
}

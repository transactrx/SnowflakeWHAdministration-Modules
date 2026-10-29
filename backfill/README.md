# backfill

Backfill columns in a Snowflake table one chunk at a time — safely, resumably, and with a permanent record of what ran.

Adding columns to a stream-fed table fills them only for new rows; every existing row stays NULL. This module deploys a generic framework that replays history through a small, table-specific **worker** procedure, one chunk per minute, stopping on the first failure and leaving a full audit trail.

← [Back to all modules](../README.md)

## Contents

- [Concepts](#concepts)
- [Usage](#usage)
- [Inputs and outputs](#inputs-and-outputs)
- [The worker contract](#the-worker-contract)
- [States](#states)
- [Running a backfill, step by step](#running-a-backfill-step-by-step)
- [Failures, alerts and recovery](#failures-alerts-and-recovery)
- [Procedure reference](#procedure-reference)
- [Plan for](#plan-for)
- [Testing the framework](#testing-the-framework)

## Concepts

| Piece | What it is | Who owns it |
|---|---|---|
| **Framework** | `BACKFILL_CONTROL`, `BACKFILL_RUN_LOG`, `BACKFILL_STATUS` and the lifecycle procedures, in the database and schema you choose | This module |
| **Worker** | One stored procedure per backfill that does the data work for one chunk | The repo that owns the target table |
| **Backfill task** | `BACKFILL_TASK_<name>`, created by `START_BACKFILL`, runs `EXECUTE_BACKFILL('<name>')` every minute, dropped on `COMPLETE` / `CANCEL` | The framework, at runtime (not Terraform) |
| **Chunk** | One time window `[start, end)` handed to the worker. Size is hours or days; default 1 day | — |
| **Cursor** | The start of the next chunk to process, in `BACKFILL_CONTROL.CURSOR_TS` | — |

Rules:

- One backfill per target table at a time. Backfills on different tables run side by side, each with its own task.
- Every backfill has a **name** that is unique forever (e.g. `TRANSACTION_LOG_182`). The name is the handle for every call.
- A failure stops that backfill on the failed chunk. Nothing is skipped silently.

## Usage

```hcl
module "backfill" {
  source = "git::https://github.com/transactrx/SnowflakeWHAdministration-Modules.git//backfill?ref=backfill-v1.1.0"

  database                 = "MY_DATABASE"
  schema                   = "MY_SCHEMA"
  notification_integration = "SNS_NOTIFICATION" # optional; omit for no failure alerts
}
```

Always pin a tag (`?ref=backfill-vX.Y.Z`), never `?ref=main`. Tags are per module; upgrading is a ref bump in your PR.

Requirements:

- Terraform >= 1.3; provider `snowflakedb/snowflake` >= 2.21.0, < 3.0.0.
- Provider preview features `snowflake_procedure_sql_resource` and `snowflake_table_resource` enabled.
- Terraform runs as **SYSADMIN** (or whichever role should own the framework). That role owns the procedures, the tasks they create, and must own or be able to call every worker.
- The owner role needs `EXECUTE TASK` (warehouse tasks) and `EXECUTE MANAGED TASK` (serverless tasks) on the account, `CREATE TASK` on the schema, `USAGE` on any warehouse a backfill names, and `USAGE` on the notification integration.
- The database and schema already exist; the caller creates them.
- Grant the procedures to no other role. They run with owner's rights.

## Inputs and outputs

| Input | Required | Description |
|---|---|---|
| `database` | yes | Database and schema the framework is created in. The caller creates them first. |
| `schema` | yes | Database and schema the framework is created in. The caller creates them first. |
| `notification_integration` | no | Set as `ERROR_INTEGRATION` on every backfill task. `null` = no alerts. |

| Output | Description |
|---|---|
| `control_table`, `run_log_table`, `status_view` | Fully qualified names |
| `procedures` | Map of fully qualified procedure names: `register`, `start`, `pause`, `resume`, `cancel`, `execute`, `cleanup` |

`BACKFILL_CONTROL` and `BACKFILL_RUN_LOG` are the permanent record of every backfill. They carry no `prevent_destroy` (since `backfill-v1.1.0`), so removing the module call, or the schema it lives in, drops them with their history. Deploy the module where it stays put; a test deployment can be removed cleanly by deleting the module call.

## The worker contract

A worker is a stored procedure, deployed with Terraform in the repo that owns the target table, added through a PR and removed after its backfill completes. The technique inside it is up to that table; the contract is fixed.

| Rule | Detail |
|---|---|
| **Signature** | `(P_START TIMESTAMP_NTZ, P_END TIMESTAMP_NTZ, P_META OBJECT)`. `P_END` is exclusive. `REGISTER_BACKFILL` checks this signature. |
| **Returns** | Rows affected (`NUMBER`). |
| **Raises on failure** | Never catch an error and return a string. Raised messages never contain PHI — codes, counts and ids only. |
| **Update-only** | `UPDATE`, or `MERGE ... WHEN MATCHED THEN UPDATE SET` only the backfilled columns. No `INSERT`. |
| **NULL guard (default)** | Update a row only where the backfilled columns are still NULL, so values the live load already wrote are never overwritten. |
| **Corrections** | A worker that overwrites existing values must be registered with a NULL end ("now"), so the replay ends on the latest source data. |
| **Re-run safe** | Running the same chunk twice leaves rows exactly as one run would, `TASK_META` included. (The NULL guard gives you this.) |
| **TASK_META** | If the target has a `TASK_META` array, prepend `P_META`: `ARRAY_PREPEND(COALESCE(t.TASK_META, ARRAY_CONSTRUCT()), :P_META)`, honoring the table's `max_history` cap. |

`P_META` is built by the framework: the six ImportFromStageTable TASK_META keys (`RUN_GROUP_ID`, `ROOT_TASK_NAME`, `ROOT_TASK_UUID`, `TASK_NAME`, `SCHEDULED_TIME`, `RUN_TIME`) plus `OPERATION = 'BACKFILL'`, `BACKFILL_NAME`, `CHUNK_START`, `CHUNK_END`, `REASON`, `REGISTERED_BY`. `RUN_GROUP_ID` is the backfill id, so a stamped row joins to `BACKFILL_CONTROL.BACKFILL_ID`.

Example worker (from [examples/test-backfill](./examples/test-backfill/main.tf)):

```sql
UPDATE TARGET_DB.TARGET_SCHEMA.MY_TABLE t
   SET NEW_COLUMN = <expression from the source>,
       TASK_META  = ARRAY_SLICE(ARRAY_PREPEND(COALESCE(t.TASK_META, ARRAY_CONSTRUCT()), :P_META), 0, 10)
 WHERE t.EVENT_TS >= :P_START
   AND t.EVENT_TS <  :P_END
   AND t.NEW_COLUMN IS NULL;
RETURN SQLROWCOUNT;
```

## States

**Backfill** (`BACKFILL_CONTROL.STATE`):

| State | Meaning | Task |
|---|---|---|
| `REGISTERED` | Validated and recorded. Nothing runs. | none |
| `ACTIVE` | Running one chunk per minute. | resumed |
| `PAUSED` | Stopped by `PAUSE_BACKFILL`. | suspended |
| `FAILED` | A chunk failed or timed out. Cursor is on that chunk. | suspended |
| `COMPLETE` | Range finished. | dropped |
| `CANCELLED` | Stopped for good by `CANCEL_BACKFILL`. | dropped |

**Chunk** (`BACKFILL_RUN_LOG.STATE`): `STARTED`, `SUCCEEDED`, `FAILED`, `TIMED_OUT`, `SKIPPED`.

Every lifecycle procedure checks the current state and changes it in one conditional update, so two simultaneous calls cannot both succeed. Calling a procedure in the wrong state raises an error naming the right call.

### End date: NULL means "now"

- **A date** — the end is **exclusive**. To include all of September 30, pass `'2026-10-01'`. The backfill completes when the cursor reaches it.
- **NULL** — keep going until caught up: the backfill completes after it processes the chunk that contains the current time. Use this for correction workers, and whenever the backfill may take long enough that "today" moves.

## Running a backfill, step by step

The examples use the module call from [Usage](#usage): the framework lives in `MY_DATABASE.MY_SCHEMA`. The table being backfilled and its worker live in `TARGET_DB.TARGET_SCHEMA`.

1. **Confirm readiness.** The new columns are live and filled for new rows. The source still covers the whole range (e.g. `MIN(INGESTED_TIMESTAMP)` of the stage table ≤ oldest target row). List streams on the target (`SHOW STREAMS IN ACCOUNT`): every backfilled row is an UPDATE to them.
2. **Write the worker** to the [contract](#the-worker-contract).
3. **Deploy the worker** through Terraform in the repo that owns the target table. Development first.
4. **Test one chunk by hand.**
   ```sql
   CALL TARGET_DB.TARGET_SCHEMA.BACKFILL_MY_TABLE('2026-03-01', '2026-03-02', OBJECT_CONSTRUCT('OPERATION', 'MANUAL_TEST'));
   CALL TARGET_DB.TARGET_SCHEMA.BACKFILL_MY_TABLE('2026-03-01', '2026-03-02', OBJECT_CONSTRUCT('OPERATION', 'MANUAL_TEST')); -- re-run: 0
   ```
   Check rows returned, rows still NULL in that window, duration and credits. Total cost ≈ one chunk × number of chunks.
5. **Register.**
   ```sql
   CALL MY_DATABASE.MY_SCHEMA.REGISTER_BACKFILL(
       'MY_TABLE_123',                                 -- name, unique forever
       'TARGET_DB.TARGET_SCHEMA.MY_TABLE',             -- target table
       'TARGET_DB.TARGET_SCHEMA.BACKFILL_MY_TABLE',    -- worker
       '2025-01-01',                                   -- start (inclusive)
       NULL,                                           -- end (exclusive); NULL = now
       'Issue #123: backfill NEW_COLUMN',              -- reason (no PHI)
       1, 'DAY',                                       -- optional: chunk size and unit (HOUR | DAY); default 1 DAY
       NULL,                                           -- optional: warehouse; NULL = serverless
       60);                                            -- optional: time limit per chunk, minutes; default 60
   ```
6. **Pause stream consumers** that should not see the updates, if any.
7. **Start.** `CALL MY_DATABASE.MY_SCHEMA.START_BACKFILL('MY_TABLE_123');` — creates `BACKFILL_TASK_MY_TABLE_123` and runs one chunk per minute.
8. **Watch.** `SELECT * FROM MY_DATABASE.MY_SCHEMA.BACKFILL_STATUS;` and `SELECT * FROM MY_DATABASE.MY_SCHEMA.BACKFILL_RUN_LOG WHERE BACKFILL_NAME = 'MY_TABLE_123' ORDER BY STARTED_AT DESC;`
9. **Pause / resume / recover** — see [below](#failures-alerts-and-recovery).
10. **Verify.** No rows in range still NULL in a column the worker always sets.
11. **Clean up.** Resume paused consumers. Remove the worker from Terraform. The task is already dropped; the control and log rows stay as the permanent record.

## Failures, alerts and recovery

When the worker raises:

1. `EXECUTE_BACKFILL` records the chunk `FAILED` and the backfill `FAILED` (both committed), with `SQLCODE`, `SQLSTATE` and the query id. The cursor stays on the failed chunk.
2. It raises a fixed message, so the task run fails.
3. `ERROR_INTEGRATION` sends **one** notification naming the task (`BACKFILL_TASK_<name>`).
4. `SUSPEND_TASK_AFTER_NUM_FAILURES = 1` suspends the task. Nothing runs until you act.

Snowflake's error text is never stored or sent — it can quote data values. Read it in query history by the query id in `LAST_ERROR` / `BACKFILL_RUN_LOG.QUERY_ID`.

When a chunk exceeds its time limit, Snowflake kills the run (one notification, task suspended) and the chunk is left `STARTED`. `BACKFILL_STATUS.STALLED` shows `TRUE`. `RESUME_BACKFILL` marks that chunk `TIMED_OUT` and retries it; shrink the chunk size or name a warehouse first.

Recovery is manual:

| Call | Effect |
|---|---|
| `RESUME_BACKFILL('<name>')` | `PAUSED` / `FAILED` / stalled → `ACTIVE`; retries the chunk at the cursor. |
| `RESUME_BACKFILL('<name>', TRUE, '<reason>')` | `FAILED` only: records the chunk `SKIPPED` with the reason and who skipped it, then moves on. For a chunk that can never succeed. |
| `CANCEL_BACKFILL('<name>')` | Stops for good; drops the task. |

### Worker changes

Each chunk calls the worker by name, so it runs whatever definition is deployed at that moment. Redeploying the worker mid-backfill (for example, fixing it after a failure) changes every chunk after that point.

Every run log row records `WORKER_HASH`: the first 12 hex characters of a SHA-256 over the worker's `GET_DDL` at the start of that chunk. `BACKFILL_STATUS.WORKER_CHANGED` is `TRUE` when the latest chunk's hash differs from the first chunk's, and `LAST_WORKER_HASH` shows the current one. Nothing is blocked; to see where a change happened:

```sql
SELECT WORKER_HASH, MIN(CHUNK_START), MAX(CHUNK_START), COUNT(*)
FROM MY_DATABASE.MY_SCHEMA.BACKFILL_RUN_LOG
WHERE BACKFILL_NAME = 'MY_TABLE_123'
GROUP BY WORKER_HASH ORDER BY 2;
```

## Procedure reference

| Procedure | From state | To state | Notes |
|---|---|---|---|
| `REGISTER_BACKFILL(name, target, worker, start, end, reason [, chunk_size, chunk_unit, warehouse, time_limit_minutes])` | — | `REGISTERED` | Validates names, worker signature, range, one-per-table. |
| `START_BACKFILL(name)` | `REGISTERED` | `ACTIVE` | Creates and resumes the task. A second call is refused. |
| `PAUSE_BACKFILL(name)` | `ACTIVE` | `PAUSED` | A chunk already running finishes. |
| `RESUME_BACKFILL(name [, skip, skip_reason])` | `PAUSED`, `FAILED`, stalled `ACTIVE` | `ACTIVE` | Skip only from `FAILED`, reason required. |
| `CANCEL_BACKFILL(name)` | any open | `CANCELLED` | Drops the task. |
| `EXECUTE_BACKFILL(name)` | `ACTIVE` | — | Called by the task. Do not call by hand while the task is running. |
| `CLEANUP_BACKFILL_TASKS()` | — | — | Drops any `BACKFILL_TASK_*` left behind by a `COMPLETE` / `CANCELLED` backfill. |

Identifiers passed in (target, worker, warehouse) must be unquoted (`[A-Z0-9_$]`); they are validated before use in DDL.

## Plan for

- Stream consumers on the target see every updated row (append-only streams do not).
- The live loader may wait on a running chunk; shrink the chunk size if it does.
- Rewritten rows keep old versions for Time Travel (14 days in Production) plus 7 days Fail-safe.
- Windows missing from the source cannot be rebuilt; such chunks succeed with 0 rows.
- Cost ≈ one chunk's credits × number of chunks. Serverless is the default; name a warehouse for heavy tables.

## Testing the framework

[examples/test-backfill](./examples/test-backfill) deploys the framework plus a test table, a one-row "fail on" switch and a contract-correct test worker. [test.sql](./examples/test-backfill/test.sql) walks through a forced failure, resume, skip, re-run and completion.

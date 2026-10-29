-- ---------------------------------------------------------------------------------------------------
-- Backfill framework end-to-end test. Run after `terraform apply` of this example.
-- Replace <DB> and <SCHEMA> with the example's database and schema. Run section by section; the
-- task runs one chunk per minute; where a step says WAIT, re-query until the expected state shows.
--
-- Proves: forced failure -> FAILED + one notification + suspended task; RESUME retries the same
-- chunk; skip records SKIPPED and moves on; a second START is refused; a re-run changes nothing;
-- the backfill reaches COMPLETE and its task is dropped.
-- ---------------------------------------------------------------------------------------------------

USE ROLE SYSADMIN;
USE SECONDARY ROLES NONE;
USE SCHEMA <DB>.<SCHEMA>;

-- 1. Seed: 5 days x 3 rows, BACKFILLED_VALUE NULL ----------------------------------------------------
TRUNCATE TABLE BACKFILL_TEST_TARGET;
TRUNCATE TABLE BACKFILL_TEST_SETTINGS;
INSERT INTO BACKFILL_TEST_TARGET (ID, EVENT_TS, SOURCE_VALUE)
SELECT SEQ4() + 1,
       DATEADD('hour', 6 * MOD(SEQ4(), 3), DATEADD('day', FLOOR(SEQ4() / 3), '2026-01-01'::TIMESTAMP_NTZ)),
       'value_' || (SEQ4() + 1)
FROM TABLE(GENERATOR(ROWCOUNT => 15));

-- 2. Worker by hand: 3 rows, then 0 on re-run (NULL guard) -------------------------------------------
CALL BACKFILL_TEST_WORKER('2026-01-01', '2026-01-02', OBJECT_CONSTRUCT('OPERATION', 'MANUAL_TEST'));  -- expect 3
CALL BACKFILL_TEST_WORKER('2026-01-01', '2026-01-02', OBJECT_CONSTRUCT('OPERATION', 'MANUAL_TEST'));  -- expect 0
UPDATE BACKFILL_TEST_TARGET SET BACKFILLED_VALUE = NULL, TASK_META = NULL;                            -- reset

-- 3. Force a failure on Jan 3 and register -----------------------------------------------------------
INSERT INTO BACKFILL_TEST_SETTINGS VALUES ('2026-01-03');

CALL REGISTER_BACKFILL(
    'BACKFILL_TEST_1',
    '<DB>.<SCHEMA>.BACKFILL_TEST_TARGET',
    '<DB>.<SCHEMA>.BACKFILL_TEST_WORKER',
    '2026-01-01', '2026-01-06',            -- end is exclusive: Jan 1 through Jan 5
    'Framework end-to-end test');
SELECT * FROM BACKFILL_STATUS WHERE BACKFILL_NAME = 'BACKFILL_TEST_1';   -- REGISTERED, no task yet
SHOW TASKS LIKE 'BACKFILL_TASK_%';                                        -- none

-- 4. Start, then start again (must be refused) -------------------------------------------------------
CALL START_BACKFILL('BACKFILL_TEST_1');
CALL START_BACKFILL('BACKFILL_TEST_1');   -- expect error -20021 "already running"

-- 5. WAIT. Expect: Jan 1 and Jan 2 SUCCEEDED, Jan 3 FAILED, state FAILED, cursor 2026-01-03,
--    task suspended, exactly one notification (if an integration is configured).
SELECT * FROM BACKFILL_STATUS WHERE BACKFILL_NAME = 'BACKFILL_TEST_1';
SELECT * FROM BACKFILL_RUN_LOG WHERE BACKFILL_NAME = 'BACKFILL_TEST_1' ORDER BY STARTED_AT;
SHOW TASKS LIKE 'BACKFILL_TASK_BACKFILL_TEST_1';                         -- state = suspended
-- LAST_ERROR and the run log hold SQLCODE / SQLSTATE / query id only; the error text is read here:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY()) WHERE QUERY_ID = '<QUERY_ID from the run log>';

-- 6. Move the failure to Jan 4 and resume: Jan 3 is retried and succeeds, Jan 4 fails ----------------
UPDATE BACKFILL_TEST_SETTINGS SET FAIL_ON_CHUNK_START = '2026-01-04';
CALL RESUME_BACKFILL('BACKFILL_TEST_1');
-- WAIT. Expect: Jan 3 SUCCEEDED (attempt 2), Jan 4 FAILED, state FAILED, cursor 2026-01-04.
SELECT * FROM BACKFILL_RUN_LOG WHERE BACKFILL_NAME = 'BACKFILL_TEST_1' ORDER BY STARTED_AT;

-- 7. Skip Jan 4 -------------------------------------------------------------------------------------
CALL RESUME_BACKFILL('BACKFILL_TEST_1', TRUE);                           -- expect error -20043 (reason required)
CALL RESUME_BACKFILL('BACKFILL_TEST_1', TRUE, 'Test: skip the forced-failure day');
-- WAIT. Expect: Jan 4 SKIPPED (with reason, ACTED_BY = you), Jan 5 SUCCEEDED, state COMPLETE.
SELECT * FROM BACKFILL_STATUS WHERE BACKFILL_NAME = 'BACKFILL_TEST_1';
SHOW TASKS LIKE 'BACKFILL_TASK_%';                                        -- none (dropped on COMPLETE)
CALL CLEANUP_BACKFILL_TASKS();                                            -- expect 'No leftover backfill tasks.'
                                                                          -- if not, the task could not drop itself

-- 8. Verify the data --------------------------------------------------------------------------------
-- Jan 4 rows still NULL (skipped); every other row filled with exactly one BACKFILL stamp.
SELECT TO_DATE(EVENT_TS) AS DAY,
       COUNT(*) AS ROWS_TOTAL,
       COUNT_IF(BACKFILLED_VALUE IS NULL) AS STILL_NULL,
       MAX(ARRAY_SIZE(TASK_META)) AS MAX_STAMPS,
       MAX(TASK_META[0]:OPERATION::VARCHAR) AS OPERATION,
       MAX(TASK_META[0]:TASK_NAME::VARCHAR) AS STAMPED_BY_TASK
FROM BACKFILL_TEST_TARGET
GROUP BY 1 ORDER BY 1;

-- The stamp joins to the run log: RUN_GROUP_ID = BACKFILL_ID.
SELECT DISTINCT t.TASK_META[0]:RUN_GROUP_ID::VARCHAR = s.BACKFILL_ID AS STAMP_JOINS
FROM BACKFILL_TEST_TARGET t
JOIN BACKFILL_STATUS s ON s.BACKFILL_NAME = 'BACKFILL_TEST_1'
WHERE t.TASK_META IS NOT NULL;

-- Worker fingerprint: one hash for the whole run (the test worker was not redeployed).
SELECT WORKER_HASH, COUNT(*) FROM BACKFILL_RUN_LOG WHERE BACKFILL_NAME = 'BACKFILL_TEST_1' AND STATE <> 'SKIPPED' GROUP BY 1;  -- expect 1 row
SELECT WORKER_CHANGED, LAST_WORKER_HASH FROM BACKFILL_STATUS WHERE BACKFILL_NAME = 'BACKFILL_TEST_1';              -- expect FALSE

-- 9. Re-run a completed chunk by hand: 0 rows, TASK_META unchanged ---------------------------------
CALL BACKFILL_TEST_WORKER('2026-01-02', '2026-01-03', OBJECT_CONSTRUCT('OPERATION', 'RERUN_TEST'));  -- expect 0
SELECT COUNT_IF(ARRAY_SIZE(TASK_META) > 1) AS DOUBLE_STAMPED FROM BACKFILL_TEST_TARGET;               -- expect 0

-- 10. Lifecycle guards on a finished backfill -------------------------------------------------------
CALL START_BACKFILL('BACKFILL_TEST_1');   -- expect -20023 (COMPLETE: register a new one)
CALL PAUSE_BACKFILL('BACKFILL_TEST_1');   -- expect -20031
CALL CANCEL_BACKFILL('BACKFILL_TEST_1');  -- expect -20061
CALL REGISTER_BACKFILL('BACKFILL_TEST_1', '<DB>.<SCHEMA>.BACKFILL_TEST_TARGET',
    '<DB>.<SCHEMA>.BACKFILL_TEST_WORKER', '2026-01-01', '2026-01-06', 'dup');  -- expect -20002 (name taken)

-- 11. Optional: open-ended ("now") backfill with hourly chunks -------------------------------------
-- UPDATE BACKFILL_TEST_TARGET SET BACKFILLED_VALUE = NULL, TASK_META = NULL;
-- INSERT INTO BACKFILL_TEST_TARGET (ID, EVENT_TS, SOURCE_VALUE)
--     SELECT 100 + SEQ4(), DATEADD('hour', -SEQ4(), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ), 'recent_' || SEQ4()
--     FROM TABLE(GENERATOR(ROWCOUNT => 3));
-- TRUNCATE TABLE BACKFILL_TEST_SETTINGS;
-- CALL REGISTER_BACKFILL('BACKFILL_TEST_NOW', '<DB>.<SCHEMA>.BACKFILL_TEST_TARGET',
--     '<DB>.<SCHEMA>.BACKFILL_TEST_WORKER', DATEADD('hour', -3, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, NULL,
--     'Framework test: NULL end', 1, 'HOUR');
-- CALL START_BACKFILL('BACKFILL_TEST_NOW');
-- WAIT ~5 minutes: COMPLETE after the chunk containing the current time; the 3 recent rows filled.

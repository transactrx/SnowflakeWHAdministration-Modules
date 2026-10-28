output "control_table" {
  description = "Fully qualified BACKFILL_CONTROL table."
  value       = "${local.fq}.${snowflake_table.control.name}"
}

output "run_log_table" {
  description = "Fully qualified BACKFILL_RUN_LOG table."
  value       = "${local.fq}.${snowflake_table.run_log.name}"
}

output "status_view" {
  description = "Fully qualified BACKFILL_STATUS view."
  value       = "${local.fq}.${snowflake_view.status.name}"
}

output "procedures" {
  description = "Fully qualified lifecycle procedure names."
  value = {
    register = "${local.fq}.${snowflake_procedure_sql.register_backfill.name}"
    start    = "${local.fq}.${snowflake_procedure_sql.start_backfill.name}"
    pause    = "${local.fq}.${snowflake_procedure_sql.pause_backfill.name}"
    resume   = "${local.fq}.${snowflake_procedure_sql.resume_backfill.name}"
    cancel   = "${local.fq}.${snowflake_procedure_sql.cancel_backfill.name}"
    execute  = "${local.fq}.${snowflake_procedure_sql.execute_backfill.name}"
    cleanup  = "${local.fq}.${snowflake_procedure_sql.cleanup_backfill_tasks.name}"
  }
}

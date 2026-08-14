####################################################
# EASY INBOUND JOBS
####################################################

locals {
  easy_job_regex = join("|", [
    "easyProfileAddressLoadJob",
    "easyProfileAddressVerifyJob",
    "easyIasLoad",
    "easyIrdDailyLoadJob",
    "easyIrdReconcileLoadJob",
    "easyCompassDataLoadJob",
    "eaBillingCalculationJob",
    "calcSettlementTiersJob",
    "mergeSplitOrgsJob"
  ])

  # Restrict application alerts to Compass Data Processing stream.
  easy_log_stream_regex = "-tg-dp\\/"

  ####################################################
  # EASY ALERT CATALOG
  ####################################################

  easy_log_alerts = {

    ##################################################
    # 1 - JOB FAILURE
    ##################################################

    job_failure = {
      name        = "Job Failure"
      description = "An EASy job encountered a terminal or execution failure."

      message_regex = join("|", [
        "Job Failure for",
        "Encountered fatal error executing job",
        "Exception thrown when trying to launch job",
        "failed on feed volume"
      ])

      severity  = "critical"
      threshold = 0
    }


    ##################################################
    # 2 - STEP EXECUTION ERROR
    ##################################################

    step_execution_error = {
      name        = "Step Execution Error"
      description = "An EASy processing step encountered an execution or batch metadata error."

      message_regex = join("|", [
        "Encountered an error executing step",
        "Encountered an error saving batch meta data"
      ])

      severity  = "critical"
      threshold = 0
    }


    ##################################################
    # 3 - JOB STOPPED / CONCURRENCY
    ##################################################

    job_stopped = {
      name        = "Job Stopped"
      description = "An EASy job was stopped, commonly because another execution was already running."

      message_regex = join("|", [
        "Stopping job .* due to .* other executions",
        "Stopped by ParallelLockoutListener",
        "job was stopped"
      ])

      severity  = "warning"
      threshold = 0
    }


    ##################################################
    # 4 - SKIP LIMIT EXCEEDED
    ##################################################

    skip_limit_exceeded = {
      name        = "Skip Limit Exceeded"
      description = "An EASy batch step exceeded its configured record skip limit."

      message_regex = join("|", [
        "Skip limit exceeded",
        "Skip Limit Exceeded",
        "SkipLimitExceededException"
      ])

      severity  = "warning"
      threshold = 0
    }


    ##################################################
    # 5 - PARSE / BIND ERROR
    ##################################################

    parse_bind_error = {
      name        = "Parse or Bind Error"
      description = "An EASy source file could not be parsed or bound according to its expected file format."

      message_regex = join("|", [
        "FlatFileParseException",
        "IncorrectLineLengthException",
        "BindException"
      ])

      severity  = "critical"
      threshold = 0
    }


    ##################################################
    # 6 - DATABASE CONSTRAINT VIOLATION
    ##################################################

    constraint_violation = {
      name        = "Constraint Violation"
      description = "EASy processing encountered a database constraint or data-integrity violation."

      message_regex = join("|", [
        "ConstraintViolationException",
        "DataIntegrityViolationException",
        "TransientPropertyValueException"
      ])

      severity  = "critical"
      threshold = 0
    }


    ##################################################
    # 7 - DUPLICATE ABA
    ##################################################

    duplicate_aba = {
      name        = "Duplicate ABA"
      description = "EASy processing detected duplicate ABA or ABA uniqueness violations."

      message_regex = join("|", [
        "duplicate ABA",
        "Duplicate ABA",
        "ABA unique constraint"
      ])

      severity  = "warning"
      threshold = 0
    }


    ##################################################
    # 8 - MISSING LOOKUP / REFERENCE DATA
    ##################################################

    missing_lookup_data = {
      name        = "Missing Lookup Data"
      description = "EASy processing encountered missing lookup or reference data required to process an inbound record."

      message_regex = join("|", [
        "Missing lookup",
        "lookup failed",
        "NULL foreign key",
        "Reference data"
      ])

      severity  = "warning"
      threshold = 0
    }


    ##################################################
    # 9 - CRITICAL RECONCILE / TIER / MERGE FAILURE
    ##################################################

    critical_operations_failure = {
      name        = "Critical Reconcile Tiering or Merge Failure"
      description = "A reconciliation, settlement-tiering, or organization-merge operation encountered an application failure."

      message_regex = join("|", [
        "Encountered an error executing step",
        "Encountered fatal error executing job",
        "Exception thrown when trying to launch job",
        "Job Failure for",
        "rollback",
        "constraint"
      ])

      severity  = "critical"
      threshold = 0

      # Only apply this alert to the three higher-risk EASy operations.
      extra_query = <<-EOT
        | filter message like /easyIrdReconcileLoadJob|calcSettlementTiersJob|mergeSplitOrgsJob/
      EOT
    }
  }
}


------

####################################################
# EASY INBOUND JOBS APPLICATION ALERTS
####################################################

module "easy_application_alerts" {
  count = var.enable_easy_alerts ? 1 : 0

  source = "./modules/application_job_alerts"

  application_name = "EASy Inbound Jobs"

  deploy_env = var.deploy_env
  aws_region = var.aws_region

  grafana_org_id = var.grafana_org_id

  cloudwatch_data_source_uid = var.cloudwatch_data_source_uid

  terraform_folder_uid = module.folders.terraform_folder_uid

  log_group_name = var.easy_log_group_name

  log_group_arn = join("", [
    "arn:",
    startswith(var.aws_region, "us-gov-") ? "aws-us-gov" : "aws",
    ":logs:",
    var.aws_region,
    ":",
    var.aws_account_id,
    ":log-group:",
    var.easy_log_group_name
  ])

  log_stream_regex = local.easy_log_stream_regex

  job_regex  = local.easy_job_regex
  log_alerts = local.easy_log_alerts

  application_runbook_url = var.easy_alerts_runbook_url

  application_dashboard_uid = var.easy_dashboard_uid

  rule_group_name = "Application Alerts"

  evaluation_interval_seconds = 300

  default_lookback_seconds = 900
  default_for_duration     = "0s"

  ##################################################
  # EASy Incoming Files DLQ
  ##################################################

  enable_dlq_alert = true

  dlq_queue_name = var.easy_dlq_queue_name
  dlq_threshold  = var.easy_dlq_threshold

  dlq_severity         = "critical"
  dlq_lookback_seconds = 900
  dlq_for_duration     = "0s"

  providers = {
    grafana = grafana.grafana-env
  }
}


----

variable "enable_easy_alerts" {
  description = "Whether EASy inbound application alerts are enabled."
  type        = bool
  default     = false
}

variable "easy_log_group_name" {
  description = "Compass ECS application log group containing EASy job logs."
  type        = string
}

variable "easy_dlq_queue_name" {
  description = "EASy incoming-files dead-letter queue name."
  type        = string
}

variable "easy_dlq_threshold" {
  description = "Visible-message threshold for the EASy DLQ."
  type        = number
  default     = 0
}

variable "easy_dashboard_uid" {
  description = "Grafana dashboard UID for the EASy Inbound Jobs Operations dashboard."
  type        = string
}

variable "easy_alerts_runbook_url" {
  description = "Runbook URL included in EASy alert annotations."
  type        = string
}

---
enable_easy_alerts = true

easy_log_group_name = "/adt-frfs-compass-${deploy_env}-e-ecs/applogs"

easy_dlq_queue_name = "adt-frfs-compass-${deploy_env}-e-sqs-incoming-files-deadletter-queue"

easy_dlq_threshold = 0


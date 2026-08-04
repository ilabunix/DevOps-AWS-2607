Below is the complete step-by-step structure using:

* A reusable application_job_alerts module
* DataLite-specific alert definitions in root locals.tf
* Environment-specific values in input.tfvars
* A small root main.tf module call
* Dynamic CloudWatch Logs ARN construction using aws_account_id
* Existing Grafana labels, annotations, datasource, folder and provider alias conventions

⸻

1. Create the module folder

Under iac/modules, create:

iac/
└── modules/
    └── application_job_alerts/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── versions.tf

⸻

2. Module versions.tf

Create:

iac/modules/application_job_alerts/versions.tf
terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "3.21.0"
    }
  }
}

⸻

3. Module variables.tf

Create:

iac/modules/application_job_alerts/variables.tf
variable "application_name" {
  description = "Application name used in alert names and labels."
  type        = string
}
variable "deploy_env" {
  description = "Deployment environment, such as dev, test, uat, or prod."
  type        = string
}
variable "aws_region" {
  description = "AWS region used by the CloudWatch datasource."
  type        = string
}
variable "grafana_org_id" {
  description = "Grafana organization ID."
  type        = number
}
variable "cloudwatch_data_source_uid" {
  description = "UID of the Grafana CloudWatch datasource."
  type        = string
}
variable "terraform_folder_uid" {
  description = "Grafana folder UID where the alert rules will be created."
  type        = string
}
variable "log_group_name" {
  description = "CloudWatch log group containing application job logs."
  type        = string
}
variable "log_group_arn" {
  description = "ARN of the CloudWatch log group."
  type        = string
}
variable "log_stream_regex" {
  description = "CloudWatch Logs Insights regex used to restrict the log stream."
  type        = string
  default     = "-tg-dp\\/"
}
variable "job_regex" {
  description = "Regex containing the business job names monitored by this module."
  type        = string
}
variable "application_runbook_url" {
  description = "Runbook URL included in alert annotations."
  type        = string
}
variable "application_dashboard_uid" {
  description = "Grafana dashboard UID included in alert annotations."
  type        = string
}
variable "rule_group_name" {
  description = "Grafana rule-group name."
  type        = string
  default     = "Application Job Alerts"
}
variable "evaluation_interval_seconds" {
  description = "How frequently Grafana evaluates the alert group."
  type        = number
  default     = 300
}
variable "default_lookback_seconds" {
  description = "Default CloudWatch Logs Insights lookback."
  type        = number
  default     = 900
}
variable "default_for_duration" {
  description = "Default duration for which a condition must remain true."
  type        = string
  default     = "0s"
}
variable "log_alerts" {
  description = "Map of application log alert definitions."
  type = map(object({
    enabled          = optional(bool, true)
    name             = string
    description      = string
    message_regex    = string
    severity         = string
    threshold        = number
    lookback_seconds = optional(number)
    for_duration     = optional(string)
    extra_query      = optional(string, "")
    labels           = optional(map(string), {})
  }))
  default = {}
}
variable "enable_dlq_alert" {
  description = "Whether the SQS DLQ rule should be created."
  type        = bool
  default     = false
}
variable "dlq_queue_name" {
  description = "SQS dead-letter queue name."
  type        = string
  default     = null
}
variable "dlq_threshold" {
  description = "DLQ visible-message threshold."
  type        = number
  default     = 0
}
variable "dlq_severity" {
  description = "Severity assigned to the DLQ alert."
  type        = string
  default     = "critical"
}
variable "dlq_lookback_seconds" {
  description = "CloudWatch metric lookback for the DLQ rule."
  type        = number
  default     = 900
}
variable "dlq_for_duration" {
  description = "Duration the DLQ condition must remain true."
  type        = string
  default     = "0s"
}

⸻

4. Module main.tf

Create:

iac/modules/application_job_alerts/main.tf
locals {
  enabled_log_alerts = {
    for alert_key, alert in var.log_alerts :
    alert_key => alert
    if try(alert.enabled, true)
  }
  common_labels = {
    email       = var.deploy_env
    environment = var.deploy_env
    application = var.application_name
  }
}
############################################
# APPLICATION LOG ALERTS
############################################
resource "grafana_rule_group" "application_log_alerts" {
  count = length(local.enabled_log_alerts) > 0 ? 1 : 0
  name             = "${var.application_name} - ${var.rule_group_name}"
  folder_uid       = var.terraform_folder_uid
  interval_seconds = var.evaluation_interval_seconds
  org_id           = var.grafana_org_id
  dynamic "rule" {
    for_each = local.enabled_log_alerts
    content {
      name      = "${var.application_name} - ${rule.value.name}"
      condition = "C"
      for = coalesce(
        try(rule.value.for_duration, null),
        var.default_for_duration
      )
      ########################################
      # A — CloudWatch Logs Insights
      ########################################
      data {
        ref_id = "A"
        relative_time_range {
          from = coalesce(
            try(rule.value.lookback_seconds, null),
            var.default_lookback_seconds
          )
          to = 0
        }
        datasource_uid = var.cloudwatch_data_source_uid
        model = jsonencode({
          datasource = {
            type = "cloudwatch"
            uid  = var.cloudwatch_data_source_uid
          }
          expression = trimspace(<<-QUERY
            fields @timestamp, message
            | filter @logStream like /${var.log_stream_regex}/
            | filter message like /(${var.job_regex})/
            | filter message like /${rule.value.message_regex}/
            ${try(rule.value.extra_query, "")}
            | stats count() as value
          QUERY
          )
          id         = ""
          intervalMs = 1000
          label      = ""
          logGroups = [
            {
              arn  = var.log_group_arn
              name = var.log_group_name
            }
          ]
          matchExact       = true
          metricEditorMode = 0
          metricName       = ""
          metricQueryType  = 0
          namespace        = ""
          period           = ""
          queryLanguage    = "CWLI"
          queryMode        = "Logs"
          refId            = "A"
          region           = var.aws_region
          sqlExpression    = ""
          statistic        = "Sum"
          statsGroups      = []
        })
      }
      ########################################
      # B — Reduce
      ########################################
      data {
        ref_id = "B"
        relative_time_range {
          from = 0
          to   = 0
        }
        datasource_uid = "__expr__"
        model = jsonencode({
          datasource = {
            type = "__expr__"
            uid  = "__expr__"
          }
          expression    = "A"
          intervalMs    = 1000
          maxDataPoints = 43200
          reducer       = "last"
          refId         = "B"
          type          = "reduce"
        })
      }
      ########################################
      # C — Threshold
      ########################################
      data {
        ref_id = "C"
        relative_time_range {
          from = 0
          to   = 0
        }
        datasource_uid = "__expr__"
        model = jsonencode({
          datasource = {
            type = "__expr__"
            uid  = "__expr__"
          }
          expression = "B"
          conditions = [
            {
              evaluator = {
                params = [rule.value.threshold]
                type   = "gt"
              }
              operator = {
                type = "and"
              }
              query = {
                params = ["B"]
              }
              reducer = {
                params = []
                type   = "last"
              }
              type = "query"
            }
          ]
          intervalMs    = 1000
          maxDataPoints = 43200
          refId         = "C"
          type          = "threshold"
        })
      }
      no_data_state  = "OK"
      exec_err_state = "Alerting"
      labels = merge(
        local.common_labels,
        {
          severity  = rule.value.severity
          alert_key = rule.key
          source    = "cloudwatch-logs"
        },
        try(rule.value.labels, {})
      )
      annotations = {
        summary          = "${var.application_name}: ${rule.value.description}"
        runbook_url      = var.application_runbook_url
        __dashboardUid__ = var.application_dashboard_uid
      }
    }
  }
}
############################################
# SQS DLQ ALERT
############################################
resource "grafana_rule_group" "application_dlq_alert" {
  count = var.enable_dlq_alert ? 1 : 0
  name             = "${var.application_name} - Queue Alerts"
  folder_uid       = var.terraform_folder_uid
  interval_seconds = var.evaluation_interval_seconds
  org_id           = var.grafana_org_id
  rule {
    name      = "${var.application_name} - DLQ Messages"
    condition = "C"
    for       = var.dlq_for_duration
    ########################################
    # A — CloudWatch SQS metric
    ########################################
    data {
      ref_id = "A"
      relative_time_range {
        from = var.dlq_lookback_seconds
        to   = 0
      }
      datasource_uid = var.cloudwatch_data_source_uid
      model = jsonencode({
        alias = "{{metric}} {{stat}}"
        datasource = {
          type = "cloudwatch"
          uid  = var.cloudwatch_data_source_uid
        }
        dimensions = {
          QueueName = [var.dlq_queue_name]
        }
        expression       = ""
        functions        = []
        group            = { filter = "" }
        highResolution   = false
        host             = { filter = "" }
        id               = ""
        instant          = false
        intervalMs       = 1000
        label            = ""
        logGroups        = []
        matchExact       = true
        maxDataPoints    = 43200
        metricEditorMode = 0
        metricName       = "ApproximateNumberOfMessagesVisible"
        metricQueryType  = 0
        mode             = 0
        namespace        = "AWS/SQS"
        options = {
          showDisabledItems = false
        }
        period        = "60"
        queryLanguage = "CWLI"
        queryMode     = "Metrics"
        range         = true
        refId         = "A"
        region        = var.aws_region
        sqlExpression = ""
        statistic     = "Maximum"
      })
    }
    ########################################
    # B — Reduce
    ########################################
    data {
      ref_id = "B"
      relative_time_range {
        from = 0
        to   = 0
      }
      datasource_uid = "__expr__"
      model = jsonencode({
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = "A"
        intervalMs    = 1000
        maxDataPoints = 43200
        reducer       = "last"
        refId         = "B"
        type          = "reduce"
      })
    }
    ########################################
    # C — Threshold
    ########################################
    data {
      ref_id = "C"
      relative_time_range {
        from = 0
        to   = 0
      }
      datasource_uid = "__expr__"
      model = jsonencode({
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression = "B"
        conditions = [
          {
            evaluator = {
              params = [var.dlq_threshold]
              type   = "gt"
            }
            operator = {
              type = "and"
            }
            query = {
              params = ["B"]
            }
            reducer = {
              params = []
              type   = "last"
            }
            type = "query"
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "C"
        type          = "threshold"
      })
    }
    no_data_state  = "OK"
    exec_err_state = "Alerting"
    labels = merge(
      local.common_labels,
      {
        severity  = var.dlq_severity
        alert_key = "dlq_messages"
        source    = "cloudwatch-metrics"
      }
    )
    annotations = {
      summary          = "${var.application_name}: messages are visible in the dead-letter queue ${var.dlq_queue_name}."
      runbook_url      = var.application_runbook_url
      __dashboardUid__ = var.application_dashboard_uid
    }
  }
}

⸻

5. Module outputs.tf

Create:

iac/modules/application_job_alerts/outputs.tf
output "log_alert_rule_group_id" {
  description = "Grafana ID for the application log alert rule group."
  value = length(grafana_rule_group.application_log_alerts) > 0 ? (
    grafana_rule_group.application_log_alerts[0].id
  ) : null
}
output "dlq_alert_rule_group_id" {
  description = "Grafana ID for the application DLQ rule group."
  value = length(grafana_rule_group.application_dlq_alert) > 0 ? (
    grafana_rule_group.application_dlq_alert[0].id
  ) : null
}

⸻

6. Add DataLite configuration to root locals.tf

If root locals.tf does not exist, create:

iac/locals.tf

Add:

locals {
  ############################################
  # DATALITE STORE JOBS
  ############################################
  datalite_job_regex = join("|", [
    "dasyRevenueStoreJob",
    "ftaStoreJob",
    "vpnStoreJob",
    "fedMailStoreJob",
    "nicBhcStoreJob",
    "pieUserStoreJob",
    "routerStoreJob",
    "udyStoreJob",
    "uimStoreJob"
  ])
  datalite_log_stream_regex = "-tg-dp\\/"
  ############################################
  # DATALITE ALERT CATALOG
  ############################################
  datalite_log_alerts = {
    job_failure = {
      name        = "Job Failure"
      description = "A DataLite Store job failed."
      message_regex = join("|", [
        "Job Failure for",
        "Job exit status \\(FAILED",
        "Encountered fatal error executing job",
        "Error in job"
      ])
      severity  = "critical"
      threshold = 0
    }
    job_stopped = {
      name        = "Job Stopped"
      description = "A DataLite Store job entered the STOPPED state."
      message_regex = join("|", [
        "Job exit status \\(STOPPED",
        "status[=: ]+STOPPED"
      ])
      severity  = "warning"
      threshold = 0
    }
    step_execution_error = {
      name        = "Step Execution Error"
      description = "A DataLite processing step encountered an execution error."
      message_regex = join("|", [
        "Encountered an error executing step",
        "Exception when creating parser",
        "Failed to initialize the reader"
      ])
      severity  = "critical"
      threshold = 0
    }
    record_count_mismatch = {
      name        = "Record Count Mismatch"
      description = "Expected and actual DataLite record counts do not match."
      message_regex = join("|", [
        "DataLite record count mismatch",
        "Possible dataLite record count mismatch",
        "RecordCountMismatchException",
        "record count mismatch"
      ])
      severity  = "warning"
      threshold = 0
    }
    volume_threshold_exceeded = {
      name        = "Volume Threshold Exceeded"
      description = "A DataLite data-volume change limit was exceeded."
      message_regex = join("|", [
        "exceeds the change limit",
        "VolumeTrackingListener",
        "volume threshold"
      ])
      severity  = "warning"
      threshold = 0
      # Prevent normal baseline/history events from triggering.
      extra_query = "| filter message not like /No history to check/"
    }
    skip_limit_exceeded = {
      name        = "Skip Limit Exceeded"
      description = "A DataLite batch step exceeded its configured skip limit."
      message_regex = join("|", [
        "Skip limit exceeded",
        "skip limit.*exceeded",
        "SkipLimitExceededException"
      ])
      severity  = "warning"
      threshold = 0
    }
    parallel_lockout = {
      name        = "Parallel Lockout"
      description = "Parallel or duplicate DataLite execution was prevented."
      message_regex = join("|", [
        "ParallelLockoutListener",
        "Cannot find Job object",
        "Stopping job"
      ])
      severity  = "warning"
      threshold = 0
    }
    file_processing_exception = {
      name        = "File Processing Exception"
      description = "A DataLite input file could not be found, parsed, bound, or validated."
      message_regex = join("|", [
        "FileNotFoundException",
        "FlatFileParseException",
        "IncorrectLineLengthException",
        "BindException"
      ])
      severity  = "critical"
      threshold = 0
    }
    data_processing_exception = {
      name        = "Data Processing Exception"
      description = "A database or data-integrity exception occurred during DataLite processing."
      message_regex = join("|", [
        "DataIntegrityViolationException",
        "ConstraintViolationException",
        "NullPointerException",
        "OptimisticLockingFailureException"
      ])
      severity  = "critical"
      threshold = 0
    }
  }
}

If you already have a locals {} block, merge these entries into it rather than creating a second conflicting block in the same file structure. Multiple locals blocks are technically valid, but one organized block is easier to maintain.

⸻

7. Add root variables

Add these to:

iac/variables.tf
############################################
# DATALITE APPLICATION ALERT VARIABLES
############################################
variable "aws_account_id" {
  description = "AWS account ID used to construct CloudWatch log group ARNs."
  type        = string
}
variable "datalite_log_group_name" {
  description = "Compass ECS log group containing DataLite application events."
  type        = string
}
variable "datalite_dlq_queue_name" {
  description = "Dead-letter queue monitored for DataLite processing."
  type        = string
}
variable "datalite_dashboard_uid" {
  description = "Grafana UID of the DataLite Store Jobs dashboard."
  type        = string
}
variable "datalite_runbook_url" {
  description = "DataLite Store Jobs playbook or runbook URL."
  type        = string
}
variable "datalite_dlq_threshold" {
  description = "Number of visible DLQ messages above which the alert fires."
  type        = number
  default     = 0
}
variable "enable_datalite_alerts" {
  description = "Controls whether DataLite application alerts are created."
  type        = bool
  default     = true
}

Do not duplicate variables you already have, such as:

deploy_env
aws_region
grafana_org_id
cloudwatch_data_source_uid
application_name

Use your existing names exactly.

⸻

8. Add the module call to root main.tf

Add this to:

iac/main.tf
############################################
# DATALITE STORE JOB APPLICATION ALERTS
############################################
module "datalite_application_alerts" {
  count = var.enable_datalite_alerts ? 1 : 0
  source = "./modules/application_job_alerts"
  application_name = "DataLite Store Jobs"
  deploy_env                 = var.deploy_env
  aws_region                 = var.aws_region
  grafana_org_id             = var.grafana_org_id
  cloudwatch_data_source_uid = var.cloudwatch_data_source_uid
  terraform_folder_uid       = module.folders.terraform_folder_uid
  log_group_name = var.datalite_log_group_name
  log_group_arn = join("", [
    "arn:",
    startswith(var.aws_region, "us-gov-") ? "aws-us-gov" : "aws",
    ":logs:",
    var.aws_region,
    ":",
    var.aws_account_id,
    ":log-group:",
    var.datalite_log_group_name
  ])
  log_stream_regex = local.datalite_log_stream_regex
  job_regex        = local.datalite_job_regex
  log_alerts       = local.datalite_log_alerts
  application_runbook_url   = var.datalite_runbook_url
  application_dashboard_uid = var.datalite_dashboard_uid
  rule_group_name             = "Application Alerts"
  evaluation_interval_seconds = 300
  default_lookback_seconds    = 900
  default_for_duration        = "0s"
  enable_dlq_alert    = true
  dlq_queue_name      = var.datalite_dlq_queue_name
  dlq_threshold       = var.datalite_dlq_threshold
  dlq_severity        = "critical"
  dlq_lookback_seconds = 900
  dlq_for_duration    = "0s"
  providers = {
    grafana = grafana.grafana-env
  }
}

The important part is now small and readable:

job_regex        = local.datalite_job_regex
log_stream_regex = local.datalite_log_stream_regex
log_alerts       = local.datalite_log_alerts

⸻

9. Add environment-specific values

In each environment’s input.tfvars, add the correct values.

For example:

iac/environments/uat/us-gov-east-1/input.tfvars
############################################
# DATALITE STORE JOB ALERTS
############################################
enable_datalite_alerts = true
aws_account_id = "REPLACE_WITH_UAT_ACCOUNT_ID"
datalite_log_group_name = "/adt-frfs-compass-uat-e-ecs/applogs"
datalite_dlq_queue_name = "REPLACE_WITH_ACTUAL_UAT_DATALITE_DLQ_NAME"
datalite_dashboard_uid = "REPLACE_WITH_DATALITE_DASHBOARD_UID"
datalite_runbook_url = "REPLACE_WITH_DATALITE_PLAYBOOK_URL"
datalite_dlq_threshold = 0

For west:

datalite_log_group_name = "/adt-frfs-compass-uat-w-ecs/applogs"

For dev east:

datalite_log_group_name = "/adt-frfs-compass-dev-e-ecs/applogs"

Use the exact real DLQ name from AWS. Do not derive it until we confirm its precise environment/region naming convention.

⸻

10. Alerts this creates

The module will create these log alerts:

Alert	Severity	Trigger
Job Failure	Critical	Failure, failed exit status or fatal job error
Job Stopped	Warning	STOPPED status
Step Execution Error	Critical	Step, parser or reader failure
Record Count Mismatch	Warning	Record count mismatch
Volume Threshold Exceeded	Warning	Volume/change limit exceeded
Skip Limit Exceeded	Warning	Batch skip limit exceeded
Parallel Lockout	Warning	Parallel/duplicate execution blocked
File Processing Exception	Critical	File, parse, line-length or binding exception
Data Processing Exception	Critical	Integrity, constraint, null or locking exception
DLQ Messages	Critical	Visible DLQ messages greater than zero

All log alerts are scoped to:

| filter @logStream like /-tg-dp\//

and only these DataLite jobs:

dasyRevenueStoreJob
ftaStoreJob
vpnStoreJob
fedMailStoreJob
nicBhcStoreJob
pieUserStoreJob
routerStoreJob
udyStoreJob
uimStoreJob

⸻

11. Format and validate

From the iac folder, run:

terraform fmt -recursive
terraform init
terraform validate
terraform plan -var-file=environments/uat/us-gov-east-1/input.tfvars

Review the plan for:

grafana_rule_group.application_log_alerts
grafana_rule_group.application_dlq_alert

The expected result is:

* One Grafana rule group containing the DataLite log rules
* One Grafana rule group containing the DLQ rule

⸻

12. Recommended first deployment

Initially, temporarily limit local.datalite_log_alerts to only one known alert, such as job_failure, or set the other entries to:

enabled = false

Deploy that one rule first and confirm in Grafana:

* The CloudWatch datasource UID is correct
* The log-group ARN is accepted
* The Logs Insights query executes
* Reduce expression B receives the count
* Threshold C evaluates correctly
* Labels route through the notification policy
* Dashboard and runbook annotations appear

After that validation, enable the remaining rules and run the pipeline again.
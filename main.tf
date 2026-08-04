Below is a reusable application_job_alerts Terraform module that fits your existing A → B → C Grafana pattern and can be instantiated for DataLite now, then EASy/WPO later.

The Grafana provider’s grafana_rule_group resource manages alert groups in a folder, and Grafana supports exporting alert definitions as Terraform when you need to compare the generated CloudWatch query model against your installed Grafana version. 

⸻

1. Create the module

iac/modules/application_job_alerts/
├── main.tf
├── variables.tf
├── output.tf
└── versions.tf

modules/application_job_alerts/versions.tf

terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "3.21.0"
    }
  }
}

⸻

modules/application_job_alerts/variables.tf

variable "application_name" {
  description = "Application name used in alert names and labels."
  type        = string
}
variable "deploy_env" {
  description = "Deployment environment such as dev, test, uat, or prod."
  type        = string
}
variable "aws_region" {
  description = "AWS region queried by the CloudWatch data source."
  type        = string
}
variable "cloudwatch_data_source_uid" {
  description = "Grafana UID of the CloudWatch data source."
  type        = string
}
variable "terraform_folder_uid" {
  description = "Grafana folder UID where alert rules are created."
  type        = string
}
variable "grafana_org_id" {
  description = "Grafana organization ID."
  type        = number
}
variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}
variable "log_group_arn" {
  description = "CloudWatch log group ARN without a trailing wildcard."
  type        = string
}
variable "log_stream_regex" {
  description = "CloudWatch Logs Insights regex used to restrict log streams."
  type        = string
  default     = "-tg-dp\\/"
}
variable "job_regex" {
  description = "Regex containing only the business jobs monitored by this module."
  type        = string
}
variable "application_runbook_url" {
  description = "Runbook URL included in Grafana alert annotations."
  type        = string
}
variable "application_dashboard_uid" {
  description = "Grafana dashboard UID included in alert annotations."
  type        = string
}
variable "rule_group_name" {
  description = "Name of the Grafana alert rule group."
  type        = string
  default     = "Application Job Alerts"
}
variable "evaluation_interval_seconds" {
  description = "Rule-group evaluation interval."
  type        = number
  default     = 300
}
variable "default_lookback_seconds" {
  description = "Default CloudWatch Logs Insights lookback window."
  type        = number
  default     = 900
}
variable "default_for_duration" {
  description = "Default duration a condition must remain true."
  type        = string
  default     = "0s"
}
variable "log_alerts" {
  description = "Application log alert definitions."
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
  description = "Whether to create the SQS DLQ alert."
  type        = bool
  default     = false
}
variable "dlq_queue_name" {
  description = "Dead-letter queue name."
  type        = string
  default     = null
}
variable "dlq_threshold" {
  description = "Visible-message threshold for the DLQ alert."
  type        = number
  default     = 0
}
variable "dlq_severity" {
  description = "Severity assigned to the DLQ alert."
  type        = string
  default     = "critical"
}
variable "dlq_lookback_seconds" {
  description = "Lookback window for the SQS DLQ metric."
  type        = number
  default     = 900
}
variable "dlq_for_duration" {
  description = "How long the DLQ threshold must remain breached."
  type        = string
  default     = "0s"
}

⸻

modules/application_job_alerts/main.tf

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
      # A: CloudWatch Logs Insights query
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
            fields @timestamp, @message, message, log_level
            | filter @logStream like /${var.log_stream_regex}/
            | filter @message like /(${var.job_regex})/
            | filter @message like /${rule.value.message_regex}/
            ${try(rule.value.extra_query, "")}
            | stats count(*) as value
          QUERY
          )
          id                = ""
          intervalMs        = 1000
          label             = ""
          logGroups = [
            {
              arn  = var.log_group_arn
              name = var.log_group_name
            }
          ]
          matchExact        = true
          metricEditorMode  = 0
          metricName        = ""
          metricQueryType   = 0
          namespace         = ""
          period            = ""
          queryLanguage     = "CWLI"
          queryMode         = "Logs"
          refId             = "A"
          region            = var.aws_region
          sqlExpression     = ""
          statistic         = "Sum"
          statsGroups       = []
        })
      }
      # B: Reduce query A to its last value
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
      # C: Trigger when B is greater than the configured threshold
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
resource "grafana_rule_group" "application_metric_alerts" {
  count = var.enable_dlq_alert ? 1 : 0
  name             = "${var.application_name} - Queue Alerts"
  folder_uid       = var.terraform_folder_uid
  interval_seconds = var.evaluation_interval_seconds
  org_id           = var.grafana_org_id
  rule {
    name      = "${var.application_name} - DLQ Messages"
    condition = "C"
    for       = var.dlq_for_duration
    # A: SQS ApproximateNumberOfMessagesVisible
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
        period            = "60"
        queryLanguage     = "CWLI"
        queryMode         = "Metrics"
        range             = true
        refId             = "A"
        region            = var.aws_region
        sqlExpression     = ""
        statistic         = "Maximum"
      })
    }
    # B: Reduce
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
    # C: Threshold
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

modules/application_job_alerts/output.tf

output "log_rule_group_id" {
  description = "Grafana ID of the application log alert rule group."
  value = length(grafana_rule_group.application_log_alerts) > 0 ? (
    grafana_rule_group.application_log_alerts[0].id
  ) : null
}
output "metric_rule_group_id" {
  description = "Grafana ID of the application metric alert rule group."
  value = length(grafana_rule_group.application_metric_alerts) > 0 ? (
    grafana_rule_group.application_metric_alerts[0].id
  ) : null
}

⸻

2. Add root variables

Add these to iac/variables.tf.

variable "aws_account_id" {
  description = "AWS account ID used to build CloudWatch log group ARNs."
  type        = string
}
variable "datalite_dashboard_uid" {
  description = "Grafana dashboard UID for the DataLite Store Jobs dashboard."
  type        = string
}
variable "datalite_runbook_url" {
  description = "DataLite Store Jobs operational playbook URL."
  type        = string
}
variable "datalite_log_group_name" {
  description = "Compass ECS application log group containing DataLite events."
  type        = string
}
variable "datalite_dlq_queue_name" {
  description = "DataLite dead-letter queue name."
  type        = string
}

You already appear to have these, so do not duplicate them:

deploy_env
aws_region
grafana_org_id
cloudwatch_data_source_uid
application_name

⸻

3. Instantiate DataLite in root main.tf

module "datalite_application_alerts" {
  source = "./modules/application_job_alerts"
  application_name            = "DataLite Store Jobs"
  deploy_env                  = var.deploy_env
  aws_region                  = var.aws_region
  grafana_org_id              = var.grafana_org_id
  cloudwatch_data_source_uid  = var.cloudwatch_data_source_uid
  terraform_folder_uid        = module.folders.terraform_folder_uid
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
  log_stream_regex = "-tg-dp\\/"
  # Only active DataLite Store jobs.
  job_regex = join("|", [
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
  application_runbook_url   = var.datalite_runbook_url
  application_dashboard_uid = var.datalite_dashboard_uid
  rule_group_name            = "Application Alerts"
  evaluation_interval_seconds = 300
  default_lookback_seconds    = 900
  default_for_duration        = "0s"
  log_alerts = {
    job_failure = {
      name        = "Job Failure"
      description = "A DataLite Store job failed or returned a failed exit status."
      message_regex = join("|", [
        "Job Failure for",
        "Job exit status \\\\(FAILED",
        "Encountered fatal error executing job",
        "Error in job"
      ])
      severity  = "critical"
      threshold = 0
    }
    stopped_job = {
      name        = "Job Stopped"
      description = "A DataLite Store job entered the STOPPED state."
      message_regex = join("|", [
        "Job exit status \\\\(STOPPED",
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
    volume_threshold = {
      name        = "Volume Threshold Exceeded"
      description = "A DataLite data-volume change limit was exceeded."
      message_regex = join("|", [
        "exceeds the change limit",
        "VolumeTracking",
        "volume threshold"
      ])
      severity  = "warning"
      threshold = 0
    }
    skip_limit = {
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
      description = "A DataLite database or data-integrity processing exception occurred."
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
  enable_dlq_alert  = true
  dlq_queue_name    = var.datalite_dlq_queue_name
  dlq_threshold     = 0
  dlq_severity      = "critical"
  dlq_for_duration  = "0s"
  providers = {
    grafana = grafana.grafana-env
  }
}

⸻

4. Environment input.tfvars

Example for UAT east:

aws_account_id = "052874758842"
datalite_log_group_name = "/adt-frfs-compass-uat-e-ecs/applogs"
datalite_dlq_queue_name = "adt-frfs-compass-uat-e-sqs-incoming-files-deadletter-queue"
datalite_dashboard_uid = "REPLACE_WITH_DATALITE_DASHBOARD_UID"
datalite_runbook_url = "REPLACE_WITH_CONFLUENCE_PLAYBOOK_URL"

Dev example:

datalite_log_group_name = "/adt-frfs-compass-dev-e-ecs/applogs"
datalite_dlq_queue_name = "adt-frfs-compass-dev-e-sqs-incoming-files-deadletter-queue"

West-region example:

datalite_log_group_name = "/adt-frfs-compass-uat-w-ecs/applogs"
datalite_dlq_queue_name = "adt-frfs-compass-uat-w-sqs-incoming-files-deadletter-queue"

⸻

Alerts included in this first release

Rule	Severity
Job Failure	Critical
Job Stopped	Warning
Step Execution Error	Critical
Record Count Mismatch	Warning
Volume Threshold Exceeded	Warning
Skip Limit Exceeded	Warning
Parallel Lockout	Warning
File Processing Exception	Critical
Data Processing Exception	Critical
DLQ Messages	Critical

I intentionally did not include a “job did not run” or “no file received” alert yet. Those are absence-based alerts and require an authoritative expected schedule per job. The screenshots state that processing generally occurs during off-hours, but they do not define a precise deadline for every job. Adding a generic absence alert without that schedule could create false positives.

One practical safeguard: create one rule manually in Grafana using the same CloudWatch Logs query, then use Export rule definition → Terraform and compare its model JSON with the module’s query model before applying all rules. Grafana explicitly supports exporting new or existing alert definitions as Terraform. 


-----------
Yes — locals.tf is a better place for the DataLite-specific alert catalog.

That keeps:

* main.tf focused on module wiring.
* variables.tf focused on external inputs.
* locals.tf focused on internal configuration like job lists, regexes, and alert definitions.
* input.tfvars limited to true environment-specific values.

Recommended structure

iac/
├── main.tf
├── variables.tf
├── locals.tf
├── providers.tf
├── versions.tf
└── modules/
    └── application_job_alerts/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── versions.tf

Root locals.tf

locals {
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
  datalite_log_alerts = {
    job_failure = {
      name        = "Job Failure"
      description = "A DataLite Store job failed."
      message_regex = join("|", [
        "Job Failure for",
        "Job exit status \\\\(FAILED",
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
        "Job exit status \\\\(STOPPED",
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
    volume_threshold = {
      name        = "Volume Threshold Exceeded"
      description = "A DataLite volume change limit was exceeded."
      message_regex = join("|", [
        "exceeds the change limit",
        "VolumeTracking",
        "volume threshold"
      ])
      severity  = "warning"
      threshold = 0
    }
    skip_limit = {
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
      description = "A DataLite data-integrity or database processing exception occurred."
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

Root main.tf

Then the module call becomes much smaller:

module "datalite_application_alerts" {
  source = "./modules/application_job_alerts"
  application_name           = "DataLite Store Jobs"
  deploy_env                 = var.deploy_env
  aws_region                 = var.aws_region
  grafana_org_id             = var.grafana_org_id
  cloudwatch_data_source_uid = var.cloudwatch_data_source_uid
  terraform_folder_uid       = module.folders.terraform_folder_uid
  log_group_name   = var.datalite_log_group_name
  log_group_arn    = var.datalite_log_group_arn
  log_stream_regex = local.datalite_log_stream_regex
  job_regex        = local.datalite_job_regex
  log_alerts       = local.datalite_log_alerts
  application_runbook_url   = var.datalite_runbook_url
  application_dashboard_uid = var.datalite_dashboard_uid
  enable_dlq_alert = true
  dlq_queue_name   = var.datalite_dlq_queue_name
  dlq_threshold    = var.datalite_dlq_threshold
  providers = {
    grafana = grafana.grafana-env
  }
}

Keep these in input.tfvars

Only values that differ by environment or region should stay in tfvars:

datalite_log_group_name = "/adt-frfs-compass-uat-e-ecs/applogs"
datalite_log_group_arn  = "arn:aws-us-gov:logs:us-gov-east-1:123456789012:log-group:/adt-frfs-compass-uat-e-ecs/applogs"
datalite_dlq_queue_name = "adt-frfs-compass-uat-e-sqs-incoming-files-deadletter-queue"
datalite_dlq_threshold  = 0
datalite_dashboard_uid = "your-dashboard-uid"
datalite_runbook_url   = "your-runbook-url"

This is the structure I would use. locals.tf is ideal for the static DataLite job allow-list and alert catalog because those are configuration owned by the codebase, not environment inputs.


locals {
  create_shared_folders = contains(["dev", "prod"], lower(var.deploy_env))

  root_folder_uid       = lower(replace(var.root_folder_name, " ", "-"))
  infra_alerts_uid      = "${local.root_folder_uid}-infra-app-alerts"
  infra_dashboards_uid  = "${local.root_folder_uid}-infra-app-dashboards"
}

resource "grafana_folder" "root" {
  count = local.create_shared_folders ? 1 : 0

  title = var.root_folder_name
  uid   = local.root_folder_uid
}

data "grafana_folder" "root" {
  count = local.create_shared_folders ? 0 : 1

  uid = local.root_folder_uid
}

resource "grafana_folder" "infra_alerts" {
  count = local.create_shared_folders ? 1 : 0

  title             = "Infrastructure & Application Health Alerts"
  uid               = local.infra_alerts_uid
  parent_folder_uid = grafana_folder.root[0].uid
}

data "grafana_folder" "infra_alerts" {
  count = local.create_shared_folders ? 0 : 1

  uid = local.infra_alerts_uid
}

resource "grafana_folder" "infra_dashboards" {
  count = local.create_shared_folders ? 1 : 0

  title             = "Infrastructure & Application Health Dashboards"
  uid               = local.infra_dashboards_uid
  parent_folder_uid = grafana_folder.root[0].uid
}

data "grafana_folder" "infra_dashboards" {
  count = local.create_shared_folders ? 0 : 1

  uid = local.infra_dashboards_uid
}

locals {
  resolved_infra_alerts_uid = local.create_shared_folders
    ? grafana_folder.infra_alerts[0].uid
    : data.grafana_folder.infra_alerts[0].uid

  resolved_infra_dashboards_uid = local.create_shared_folders
    ? grafana_folder.infra_dashboards[0].uid
    : data.grafana_folder.infra_dashboards[0].uid
}

resource "grafana_folder" "dashboard_folder" {
  title             = var.terraform_folder_name
  parent_folder_uid = local.resolved_infra_alerts_uid
}
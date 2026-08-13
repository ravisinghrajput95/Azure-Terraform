# monitor

Action group and Azure Monitor metric alert rules for the AKS cluster.

Module 20 of 22. Deployed last, after the resources it observes exist, so the
initial deployment does not page anyone while things are still coming up.

Lives in the `mon` resource group, deliberately outside the `app` group, so
tearing down a dev app stack does not destroy the thing that would have told
you it went down.

---

## Everything this module can get wrong is silent

This is the module's defining characteristic and the reason it carries as many
preconditions as it does.

A metric alert rule that names a metric AKS does not publish is **accepted** by
Azure. So is one using an aggregation the metric does not support, and one
filtering on a dimension the metric does not carry. In all three cases the rule
is created, appears in the portal as enabled and healthy, and **never fires**.

There is no error at apply time, nothing unusual in the plan, and no degraded
state to notice later. The gap is discovered when an incident passes unalerted
— which is to say, at the worst possible moment and with no indication that
alerting was ever the problem.

The same is true of an action group with no receivers: every rule evaluates,
fires and resolves exactly as designed, and notifies nobody.

So the module validates against a catalogue of what AKS actually publishes:

| Guard | What it prevents |
|---|---|
| `email_receivers` non-empty | Alerts that fire correctly and tell nobody |
| `metric_name` in catalogue | A rule on a metric that does not exist |
| `aggregation` supported by that metric | A rule Azure accepts and never evaluates |
| `dimension.name` carried by that metric | A filter matching no time series |
| `window_size >= frequency` | An Azure rejection naming neither value |
| `cluster_autoscaler_*` only when the autoscaler runs | A rule on a metric nothing is publishing |
| `threshold_overrides` keys match real rules | An override silently ignored |

The dimension check is the most valuable of these, because a
dimension-filtered rule reads as *more* precisely targeted than an unfiltered
one. A typo there produces something that looks like careful work.

### The catalogue is read from Azure, not from documentation

`locals.tf` holds all 27 AKS metrics with their supported aggregations and
dimensions. It was generated from a live cluster:

```bash
az monitor metrics list-definitions \
  --resource "$(az aks show -g <rg> -n <cluster> --query id -o tsv)"
```

Documented metric lists drift from what a given cluster and provider version
actually expose. Regenerate the catalogue against the target cluster rather
than trusting either the docs or this file if a rule unexpectedly never fires.

All 27 are **free platform metrics**. None require Container Insights or
managed Prometheus, so alerting on them adds no ingestion cost — which matters
where the workspace has a daily cap.

### The catalogue is necessary but not sufficient

A metric can be in the catalogue, valid in every respect, and still publish
nothing.

The `cluster_autoscaler_*` metrics exist on every AKS cluster and are accepted
by every alert rule, but the autoscaler only emits them **when it is actually
running**. This module originally alerted on
`cluster_autoscaler_unschedulable_pods_count`; querying the live dev cluster
returned **zero data points**, because dev's system pool has autoscaling off.
The rule was created, showed as healthy, and could never have fired.

The catalogue cannot catch that — the metric genuinely exists — so the
dependency is declared instead, via `cluster_autoscaler_enabled`. Detecting
unschedulable pods without the autoscaler is what `kube_pod_status_phase` with
`phase=Pending` is for, and it publishes unconditionally.

The general lesson: **confirm a metric returns data on the target cluster**
before trusting a rule built on it.

```bash
az monitor metrics list --resource "$AKS_ID" \
  --metric kube_pod_status_phase --aggregation Average \
  --filter "phase eq '*'" --interval PT5M
```

### A threshold below the steady state is its own failure

An alert that fires permanently is as useless as one that never fires; the
failure is just louder, and it trains people to ignore the channel.

dev runs a standing **2 pods in Pending** on a healthy cluster — DaemonSet
replicas with no second node to land on — against 25 running. A
`Pending > 0` rule would have fired from the moment it deployed. `dev`
therefore sets `threshold_overrides = { pods-pending = 3 }`, measured rather
than guessed.

Baselines are environment-specific. Measure before setting a threshold.

---

## Default rule set

Chosen for a **single-node, non-HA** cluster, where node-level problems are
total outages rather than degradations.

| Key | Metric | Severity | Why |
|---|---|---|---|
| `node-not-ready` | `kube_node_status_condition` | 0 Critical | One node. NotReady is the whole cluster. |
| `node-cpu-high` | `node_cpu_usage_percentage` | 2 | Throttling starts long before an outage is visible |
| `node-memory-high` | `node_memory_working_set_percentage` | 2 | The kubelet evicts pods under pressure first |
| `node-disk-high` | `node_disk_usage_percentage` | 2 | Disk pressure taints the node; image pulls fail |
| `pods-failed` | `kube_pod_status_phase` | 2 | Genuine workload failure, distinct from pending |
| `pods-pending` | `kube_pod_status_phase` (`phase=Pending`) | 2 | Usually the 4 vCPU quota, and waiting never fixes it |
| `apiserver-cpu-high` | `apiserver_cpu_usage_percentage` | 1 | Free SKU tier carries **no** control-plane SLA |
| `etcd-database-high` | `etcd_database_usage_percentage` | 1 | A full etcd goes read-only and is hard to recover |

Every threshold is an input. The right value depends on node size and workload,
not on this module.

---

## Cost

Metric alerts bill **per evaluated time series, not per rule**, at roughly
$0.10 per series per month at US list price. A rule with no dimension filter is
one series; splitting on a dimension multiplies it by the number of values that
dimension takes.

The default set is eight rules, so roughly **$0.80/month** — but
`indicative_monthly_cost_usd` counts rules, which makes it a **floor** wherever
dimensions are in use, not an estimate. Action groups themselves are free, as
are the first 1,000 emails per month.

Verify against the Azure Pricing Calculator before relying on any of this.

---

## Usage

```hcl
module "monitor" {
  source = "../../modules/monitor"

  count = module.profile.enable_alerts ? 1 : 0

  action_group_name       = module.naming.names.action_group
  action_group_short_name = "ccrt-dev"
  resource_group_name     = module.resource_group.names["mon"]
  location                = var.location
  tags                    = module.tags.tags

  email_receivers = { platform = var.alert_email_address }

  cluster_id        = module.aks.id
  alert_name_prefix = "alrt-${module.naming.base}"

  cluster_autoscaler_enabled = module.profile.enable_autoscale

  # Measured against the running cluster, not guessed.
  threshold_overrides = { pods-pending = 3 }
}
```

`count` on the module call is derived from `profile`, which is pure computation
over variables — so it stays statically known and survives a cold apply.

## Key inputs

| Name | Default | Description |
|---|---|---|
| `email_receivers` | `{}` | **Empty is rejected.** Alerts that notify nobody. |
| `cluster_id` | — | AKS cluster the rules are scoped to. |
| `metric_alerts` | 8 rules | Validated against the catalogue. |
| `action_group_enabled` | `true` | False silences delivery; reported in an output. |
| `threshold_overrides` | `{}` | Per-rule thresholds. Unknown keys rejected. |
| `cluster_autoscaler_enabled` | `false` | Gates rules on `cluster_autoscaler_*` metrics. |
| `default_severity` | `2` | 0 Critical … 4 Verbose. |
| `default_frequency` | `PT5M` | Shorter costs more. |
| `default_window_size` | `PT15M` | Must be >= frequency. |

## Key outputs

| Name | Description |
|---|---|
| `coverage_summary` | Posture in plain language, including the degraded states |
| `enabled_alert_count` | Rules actually evaluating |
| `disabled_alerts` | Rules deployed but switched off |
| `notifications_are_delivered` | False when the action group is disabled |
| `metrics_monitored` | Alert key to metric, for confirming coverage |

---

## Not covered

Out of scope by decision, not oversight:

- **Log Analytics daily cap** — dev caps ingestion at 0.5 GB/day, and a hit cap
  *drops* data unrecoverably, including security signals. Worth adding.
- **Data tier** — SQL, Redis, Storage, Key Vault availability and throttling.
- **Subscription budget** — free, and directly relevant to a credit-limited
  subscription.
- **Service Health** — activity log alerts for Azure-side incidents, also free.

Adding any of these is a new entry in `metric_alerts`, or an
`azurerm_monitor_activity_log_alert` attached to the exported
`action_group_id`.

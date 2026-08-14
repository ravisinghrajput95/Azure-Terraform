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

## The Log Analytics daily cap alert

A ninth rule, off by default, and the only log search alert here — the other
eight are metric alerts.

**Why it matters more than its severity suggests.** When a workspace hits its
daily ingestion cap, collection stops for the remainder of the UTC day. The
dropped telemetry is not queued, not backfilled, and not recovered by raising
the cap afterwards — it is simply gone. Every metric alert above goes blind at
the same moment, because the metrics they watch stop arriving. A capped
workspace that hits its cap therefore disables this entire module silently, and
this is the rule that says so.

dev caps at **0.5 GB/day**, and hits it **daily** — on 2026-08-13, and again on
2026-08-14 within six hours of the 11:00 UTC reset. Before these rules existed,
nothing reported either.

**What consumes it is AKS audit logging**, measured on 2026-08-14:

| Data type | Volume | Share |
|---|---|---|
| `AzureDiagnostics` | 509.36 MB | 99% |
| `AzureMetrics` | 4.38 MB | 1% |

and within `AzureDiagnostics`, by record count over 24h:

| Category | Records |
|---|---|
| `kube-audit` | 318,192 |
| `kube-audit-admin` | 146,452 |
| everything else combined | ~52,000 |

The two audit categories are ~90% of all diagnostic records. This is a direct
consequence of the design in ARCHITECTURE.md §1.4: the `diagnostics` module
reads `azurerm_monitor_diagnostic_categories` and enables **every** category the
resource offers. That is the right default for most resources and the wrong one
for AKS, where `kube-audit` records every API server call and will exhaust a
0.5 GB cap on its own. Not yet fixed — see "Not covered".

### The documented query does not work, and fails silently

Microsoft's guidance filters on the `Operation` column:

```kusto
_LogOperation
| where Category =~ "Ingestion"
| where Operation =~ "Data collection Status"   // matches NOTHING here
| where Detail contains "OverQuota"
```

On this platform's workspace `Operation` holds a **GUID**, not that string.
Verified against the live workspace on a day the cap had genuinely been hit:

```
Category   Operation                              Detail
Ingestion  995abe77-99ad-4625-9b17-10f3023cc330   "Data collection stopped due to
                                                   daily limit of free data reached.
                                                   Ingestion status = OverQuota"
```

Both queries were run against that record, constrained to the rule's one-hour
window:

| Query | Rows matched | Would fire |
|---|---|---|
| Documented, filtering `Operation` | **0** | no |
| This module's, filtering `Category` + `Detail` | **1** | **yes** |

A rule built the documented way is accepted by Azure, **passes query
validation** — the syntax is valid and the table exists — displays as enabled
and healthy, and never fires while the workspace silently drops data.

That is why the query is fixed in `locals.tf` rather than exposed as an input,
and why a test asserts it never filters on `Operation`. There is no error to
find later.

### Four settings that are deliberate, not defaults

| Setting | Value | Why |
|---|---|---|
| `auto_mitigation_enabled` | `false` | Auto-resolve fires when the row ages out of the window, roughly an hour later. The cap is still in force until the daily reset, so resolving would signal "recovered" while data is still being dropped. |
| `window_duration` | `PT1H` vs `PT15M` frequency | The OverQuota row is written once. Its `TimeGenerated` is when the cap was hit, not when the row became queryable — ingestion latency sits between them, and a window equal to the frequency can step past a late-arriving row and miss the only notification there will be that day. |
| `mute_actions_after_alert_duration` | `PT6H` | The consequence of the above: one cap hit is matched by several consecutive evaluations. Without muting that is a stream of identical alerts. The cap resets daily, so muting for hours loses nothing. |
| `failing_periods` | `1` of `1`, not exposed | The row appears once. Requiring more failing periods waits for a repeat that never comes, and would silence the rule with no indication it had been silenced. |

`skip_query_validation` is left `false` so that a query naming a table that does
not exist fails the apply rather than deploying a rule that cannot match.

### The precondition that matters

An **uncapped** workspace never stops ingesting, so it never emits the record
this query matches. The rule would be created, validate, display as healthy and
never fire. `log_analytics_daily_quota_gb` is therefore passed in — so the check
runs at plan time — and `-1` with the alert enabled is rejected outright.

In this platform the flag is derived from the cap itself:

```hcl
enable_daily_cap_alert       = module.profile.profile.log_daily_quota_gb > 0
log_analytics_daily_quota_gb = module.profile.profile.log_daily_quota_gb
log_analytics_workspace_id   = module.log_analytics.id
```

The alert exists exactly where there is a cap to hit. `profile`'s production
guardrail forces `log_daily_quota_gb = -1` outside dev, so this is `false`
everywhere else **without the monitor module ever learning which environment it
is in**.

### What is verified, and what is not

- **Verified:** the query matches a real OverQuota record, and would have fired
  on the actual cap hit. The documented query would not have.
- **Verified:** the rule is deployed, enabled, severity 1, scoped to the
  workspace, with the query as written.
- **NOT verified:** the rule has never fired, so notification delivery is
  untested end to end. Nothing confirms the email arrives.

---

## The daily cap WARNING alert

A tenth rule. The one above reports a cap that has already been hit; this one
reports a cap about to be hit, which is the only one of the two that can still
be acted on.

**It would have given ~44 minutes of warning.** Reconciled against the real
2026-08-13 cap hit, summing billable `Usage` by `EndTime` from the 11:00 UTC
reset:

| EndTime (UTC) | hour | cumulative | % of 0.5 GB |
|---|---|---|---|
| 20:00 | 134.71 MB | 305.82 MB | 60% |
| 21:00 | 133.23 MB | **439.05 MB** | **86%** ← 80% crossed |
| 22:00 | 105.15 MB | 544.20 MB | 106% → OverQuota at **21:44** |

### Three values that were measured, not assumed

Each is silent if wrong: the query stays valid, the rule stays healthy, and the
number is simply incorrect.

| | Wrong-but-intuitive | Correct here | Why it matters |
|---|---|---|---|
| Period start | `startofday()` or `ago(24h)` | the **cap reset hour** | This workspace resets at **11:00 UTC**, not midnight. `ago(24h)` spans two cap periods and over-counts; `startofday()` under-counts for the 11 hours after midnight. |
| Time column | `TimeGenerated` | **`EndTime`** | `EndTime` is the usage period the quantity belongs to; `TimeGenerated` is when the summary row was written. They diverge under ingestion latency — exactly when the number matters. |
| MB per GB | 1000 | **1024** | `Usage.Quantity` is MB, `dailyQuotaGb` is GB. Dividing by 1000 reports ~2.4% low, enough to push an 80% warning past the cap it exists to precede. |

Read the reset hour from the workspace rather than assuming it:

```bash
az monitor log-analytics workspace show -g <rg> -n <name> \
  --query workspaceCapping.quotaNextResetTime -o tsv
```

`daily_cap_reset_hour_utc` has **no default** for this reason. A wrong hour
cannot be detected at plan time, and one set too late in the day sums a window
that has barely started — so the total stays near zero and the warning never
fires.

### The measure is a percentage, not a size

`metric_measure_column = "PercentOfDailyCap"` with `threshold = 80`, so the rule
reads as "80" in the portal and does not need recomputing if the cap changes.
`time_aggregation_method` is `Maximum` rather than `Total`: the query returns
one row, and if it ever returned more, `Total` would sum percentages into a
meaningless number.

### Auto-mitigation and muting are alternatives, not complements

Azure rejects both at once:

```
auto mitigation must be disabled when mute action duration is set
```

| Rule | Setting | Why |
|---|---|---|
| Cap **hit** | auto-mitigation **off**, mute `PT6H` | Stateless: it re-notifies on every matching evaluation, so it needs muting. Auto-resolve would claim recovery while data is still being dropped. |
| Cap **warning** | auto-mitigation **on**, no mute | Stateful: notifies once, stays open while ingestion is above the threshold, and resolves by itself when the period rolls over — which is accurate here. |

### The window is load-bearing

`window_duration` is the rule's outer time filter, and the query sums back to a
reset up to 24 hours ago. A window shorter than the cap period **clips the sum**:
the total comes out low, the threshold is never crossed, and the rule never
fires while the workspace sails past its cap. A precondition rejects anything
below `P1D`.

### Both rules have now fired, on a real cap hit

Deployed 2026-08-14 and confirmed firing the same day, against a genuine cap
breach rather than a synthetic one:

```
alrt-cloudcart-dev-cus-daily-cap-warning   Sev2   fired 16:35:06Z
alrt-cloudcart-dev-cus-daily-cap           Sev1   fired 16:26:30Z, again 16:41:29Z
```

Two things that observation settled:

- **Muting suppresses notifications, not alert instances.** The cap-hit rule
  carries `mute_actions_after_alert_duration = PT6H` and still produced a new
  alert record on consecutive 15-minute evaluations. The mute applies to the
  *action* — the email — not to alert creation. Reading the alert list and
  concluding the mute is broken is a mistake worth not making twice.
- **What is still unverified:** that the notification reaches the mailbox.
  Alerts fired and the action group is attached, but delivery to an inbox
  cannot be confirmed from the API.

### Why not a metric alert

The workspace publishes an `Ingestion Volume` metric, which looks like the
obvious basis for this. It is not usable: it supports only the `Count`
aggregation — counting samples, not bytes — and a metric alert evaluates a
rolling window, which cannot express "cumulative since the 11:00 reset". Checked
against the metric definitions API before writing the log query.

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

The two daily-cap rules are **log search** alerts, priced differently again —
per rule, varying with evaluation frequency, rather than per time series. They
are counted as a separate ~$0.50/month term each, bringing dev to roughly
**$1.80/month**.

Verify against the Azure Pricing Calculator before relying on any of this. Both
figures are order-of-magnitude planning aids, not budget numbers.

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

  # Derived from the cap, not the environment name.
  enable_daily_cap_alert       = module.profile.profile.log_daily_quota_gb > 0
  log_analytics_daily_quota_gb = module.profile.profile.log_daily_quota_gb
  log_analytics_workspace_id   = module.log_analytics.id

  # Measured from the workspace, not assumed — this one resets at 11:00 UTC.
  enable_daily_cap_warning_alert = module.profile.profile.log_daily_quota_gb > 0
  daily_cap_reset_hour_utc       = 11
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
| `enable_daily_cap_alert` | `false` | Capability flag. **Rejected when the workspace is uncapped** — the rule could never fire. |
| `log_analytics_workspace_id` | `null` | The workspace's ARM `id`, **not** `workspace_id` (the customer GUID, which is not a valid scope). |
| `log_analytics_daily_quota_gb` | `-1` | Passed in so the precondition evaluates at plan time. |
| `daily_cap_alert_severity` | `1` | Data is already being dropped, and every rule above is blind. |
| `daily_cap_alert_window_duration` | `PT1H` | Deliberately longer than the frequency — see above. |
| `daily_cap_alert_mute_duration` | `PT6H` | Suppresses repeat notifications for one cap hit. |
| `enable_daily_cap_warning_alert` | `false` | The rule that fires *before* data is lost. |
| `daily_cap_warning_percent` | `80` | Must be below 100, or it warns after the fact. |
| `daily_cap_reset_hour_utc` | **no default** | Must be read from the workspace. Not midnight everywhere. |
| `daily_cap_warning_window_duration` | `P1D` | Shorter clips the cap period and the rule never fires. |

## Key outputs

| Name | Description |
|---|---|
| `coverage_summary` | Posture in plain language, including the degraded states |
| `enabled_alert_count` | Rules actually evaluating |
| `disabled_alerts` | Rules deployed but switched off |
| `notifications_are_delivered` | False when the action group is disabled |
| `metrics_monitored` | Alert key to metric, for confirming coverage |
| `daily_cap_alert_is_deployed` | False means a capped workspace can stop collecting with no notification |
| `daily_cap_alert_query` | The KQL, so it can be run by hand — the only way to confirm the rule would fire |
| `daily_cap_warning_is_deployed` | False means the only cap alerting arrives after data is already lost |
| `daily_cap_warning_query` | The warning KQL with cap and reset hour substituted, for checking the period boundary |

---

## Not covered

Out of scope by decision, not oversight:

- **Excluding `kube-audit` from the AKS diagnostic setting** — it is ~90% of
  dev's ingestion and single-handedly exhausts the 0.5 GB/day cap, but the
  `diagnostics` module enables every category a resource offers by design
  (ARCHITECTURE.md §1.4). Narrowing it is a change to that module's contract,
  not to this one, and audit logs are a security signal — dropping them is a
  decision, not a cleanup.

- **Data tier** — SQL, Redis, Storage, Key Vault availability and throttling.
- **Subscription budget** — free, and directly relevant to a credit-limited
  subscription.
- **Service Health** — activity log alerts for Azure-side incidents, also free.

Adding any of these is a new entry in `metric_alerts`, or an
`azurerm_monitor_activity_log_alert` attached to the exported
`action_group_id`.

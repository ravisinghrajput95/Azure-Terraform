#!/usr/bin/env bash
#
# check-ingestion.sh — how close is a workspace to its daily cap?
#
# THE QUERY HERE IS NOT THE ONE MICROSOFT DOCUMENTS, AND THAT IS DELIBERATE.
#
# The documented cap query filters on the Operation column:
#
#   _LogOperation | where Operation =~ "Data collection Status"
#
# On this platform's workspace that column holds a GUID, not that string. Both
# queries were run against a real OverQuota record on 2026-08-14: the
# documented one matched 0 rows, the one below matched 1. A rule built the
# documented way is accepted by Azure, passes query validation, displays as
# healthy, and never fires while the workspace silently drops data.
#
# Three further things measured rather than assumed, all of which this script
# depends on:
#
#   - The cap period starts at the RESET HOUR, not midnight and not ago(24h).
#     Read it from workspaceCapping.quotaNextResetTime.
#   - Filter on EndTime, not TimeGenerated. EndTime is the usage period the
#     quantity belongs to; TimeGenerated is when the row was written, and the
#     two diverge under ingestion latency — exactly when the number matters.
#   - A GB is 1024 MB here. Dividing by 1000 reports ~2.4% low.
#
# Usage: scripts/check-ingestion.sh <resource-group> <workspace-name>

set -euo pipefail

RG="${1:-}"; WS="${2:-}"
[ -n "$RG" ] && [ -n "$WS" ] || { echo "usage: $0 <resource-group> <workspace-name>" >&2; exit 2; }

az group exists -n "$RG" 2>/dev/null | grep -q true || {
  echo "resource group '$RG' does not exist in the current subscription." >&2
  echo "Nothing to check. Confirm the environment is deployed first." >&2
  exit 3; }

capping=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query workspaceCapping -o json)
quota=$(echo "$capping" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dailyQuotaGb"))')
status=$(echo "$capping" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dataIngestionStatus"))')
reset=$(echo "$capping" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("quotaNextResetTime") or "")')

echo "workspace   : ${WS}"
echo "daily cap   : ${quota} GB"
echo "status      : ${status}"
echo "next reset  : ${reset}"

if [ "$quota" = "-1" ] || [ "$quota" = "None" ]; then
  echo
  echo "UNCAPPED. Ingestion is billed rather than stopped, so there is nothing"
  echo "to approach. Note that a cap alert on this workspace could never fire —"
  echo "an uncapped workspace never emits the OverQuota record."
  exit 0
fi

hour=$(echo "$reset" | cut -dT -f2 | cut -d: -f1 | sed 's/^0//')
hour=${hour:-0}
guid=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query customerId -o tsv)

echo
echo "cap period starts at ${hour}:00 UTC"
echo

az monitor log-analytics query -w "$guid" --analytics-query "
let capGB = ${quota};
let resetHour = ${hour}h;
let periodStart = iff(now() - startofday(now()) >= resetHour,
                      startofday(now()) + resetHour,
                      startofday(now() - 1d) + resetHour);
Usage
| where IsBillable == true
| where EndTime > periodStart
| summarize IngestedMB = sum(Quantity) by DataType
| extend PercentOfCap = IngestedMB / 1024.0 / capGB * 100.0
| order by IngestedMB desc
" -o json | python3 -c '
import json,sys
rows=json.load(sys.stdin)
if not rows:
    print("  no billable ingestion in the current cap period"); sys.exit()
tot=0.0
print(f"  {\"data type\":30}{\"MB\":>10}{\"% of cap\":>10}")
for r in rows:
    mb=float(r["IngestedMB"]); tot+=mb
    print(f"  {r[\"DataType\"]:30}{mb:10.2f}{float(r[\"PercentOfCap\"]):10.1f}")
print(f"  {\"TOTAL\":30}{tot:10.2f}")
'

echo
echo "Has the cap actually been hit in the retained window?"
az monitor log-analytics query -w "$guid" --analytics-query '
_LogOperation
| where Category =~ "Ingestion"
| where Detail has "OverQuota"
| project TimeGenerated, Detail
| order by TimeGenerated desc
| take 5
' -o json | python3 -c '
import json,sys
rows=json.load(sys.stdin)
if not rows:
    print("  no OverQuota records — the cap has not been hit in the retained window")
else:
    for r in rows:
        print(f"  {r[\"TimeGenerated\"][:19]}  {r[\"Detail\"]}")
'

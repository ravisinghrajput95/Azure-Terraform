#!/usr/bin/env bash
#
# preflight.sh — can this subscription actually host this environment?
#
# ARCHITECTURE.md §6a exists because this check did not. Azure SQL turned out
# to be restricted in East US *for this subscription*, which is invisible in
# the documentation and only surfaces when an apply fails. Discovering it at
# module 15 cost a rebuild of 28 resources. Discovering it after compute,
# cache and gateway existed would have been materially worse.
#
# Regional availability published by Microsoft is necessary and NOT sufficient.
# Subscription-level restrictions are a different thing and there is no API
# that lists them, which is why the SQL check here provisions a throwaway
# logical server rather than reading a capability flag.
#
# Usage:
#   scripts/preflight.sh <region> [--required-vcpu N] [--vm-size SIZE] [--probe-sql]
#
# Exit codes: 0 all checks passed, 1 at least one hard blocker.

set -euo pipefail

REGION="${1:-}"; shift || true
REQUIRED_VCPU=""; VM_SIZE=""; PROBE_SQL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --required-vcpu) REQUIRED_VCPU="$2"; shift 2 ;;
    --vm-size)       VM_SIZE="$2";       shift 2 ;;
    --probe-sql)     PROBE_SQL=1;        shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REGION" ] || { echo "usage: $0 <region> [--required-vcpu N] [--vm-size SIZE] [--probe-sql]" >&2; exit 2; }

fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

echo "Preflight against $(az account show --query name -o tsv) in ${REGION}"
echo

echo "Subscription"
# NOT `az account show` — that command does not return subscriptionPolicies at
# all, and querying it there silently yields None rather than an error. The
# quota id and spending limit live on the ARM subscription endpoint.
sub=$(az account show --query id -o tsv)
pol=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/${sub}?api-version=2022-12-01" -o json 2>/dev/null \
  | python3 -c 'import json,sys; p=(json.load(sys.stdin).get("subscriptionPolicies") or {}); print(p.get("quotaId","unknown"), p.get("spendingLimit","unknown"))' 2>/dev/null || echo "unknown unknown")
offer=$(echo "$pol" | cut -d" " -f1)
limit_state=$(echo "$pol" | cut -d" " -f2)
note "quota id: ${offer}   spending limit: ${limit_state}"
case "$offer" in
  *FreeTrial*|*MSDN*|*Free*) warn "trial or credit-based offer: quota increases cannot be requested on it." ;;
  *) ok "not a trial offer" ;;
esac
case "$limit_state" in
  On) warn "spending limit ON: at credit exhaustion the subscription is DISABLED, not billed. Resources stop; they are not deleted." ;;
esac
echo

echo "Regional vCPU"
read -r used limit < <(az vm list-usage -l "$REGION" \
  --query "[?name.value=='cores'].[currentValue,limit]" -o tsv 2>/dev/null || echo "0 0")
avail=$(( limit - used ))
note "cores: ${used} used of ${limit}  ->  ${avail} available"
note "this is a TOTAL across every VM family; a per-family limit does not raise it"
if [ -n "$REQUIRED_VCPU" ]; then
  if [ "$avail" -ge "$REQUIRED_VCPU" ]; then
    ok "${REQUIRED_VCPU} vCPU required, ${avail} available"
  else
    bad "${REQUIRED_VCPU} vCPU required, only ${avail} available. AKS also adds a surge node during upgrades, so a cluster that exactly fits cannot be patched."
  fi
fi
echo

if [ -n "$VM_SIZE" ]; then
  echo "VM size ${VM_SIZE}"
  restrictions=$(az vm list-skus -l "$REGION" --size "$VM_SIZE" --query "[0].restrictions[].reasonCode" -o tsv 2>/dev/null || true)
  if [ -z "$restrictions" ]; then
    ok "available and unrestricted in ${REGION}"
  else
    bad "restricted in ${REGION}: ${restrictions}"
    note "a restricted size fails at apply with an error that names the scale set, not the size"
  fi
  echo
fi

echo "Azure SQL provisioning"
if [ "$PROBE_SQL" -eq 1 ]; then
  rg="rg-preflight-$RANDOM"
  srv="sqlpreflight$RANDOM"
  note "creating a throwaway logical server (free, deleted immediately)"
  az group create -n "$rg" -l "$REGION" -o none 2>/dev/null || true
  if az sql server create -g "$rg" -n "$srv" -l "$REGION" \
       --admin-user preflight --admin-password "$(openssl rand -base64 24)Aa1!" -o none 2>/dev/null; then
    ok "Azure SQL can be provisioned in ${REGION} for this subscription"
  else
    bad "Azure SQL provisioning is RESTRICTED in ${REGION} for this subscription"
    note "this is per-subscription, not capacity, and does not resolve on its own"
    note "probe other regions before building anything that depends on SQL"
  fi
  az group delete -n "$rg" --yes --no-wait -o none 2>/dev/null || true
else
  warn "skipped. There is NO API that reports this — the only reliable check is"
  note "attempting a create. Re-run with --probe-sql to provision and immediately"
  note "delete a throwaway logical server. It is free and takes under a minute."
fi
echo

if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "At least one blocker. Do not start building."
fi
exit "$fail"

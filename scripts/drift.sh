#!/usr/bin/env bash
#
# drift.sh — does Azure still match the code, per environment?
#
# Runs `terraform plan -detailed-exitcode` against every environment that has
# a backend configured, and reports each one. Read-only: it takes the state
# lock briefly and releases it, and never applies.
#
# Exit code 2 from plan means "changes pending", which is drift when nobody
# has edited the code — someone changed something in the portal, or an Azure
# default moved underneath the configuration.
#
# Usage: scripts/drift.sh [environment ...]     (default: all configured)

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
ENVS=("$@")
[ ${#ENVS[@]} -eq 0 ] && ENVS=(dev qa stage prod)

overall=0
for env in "${ENVS[@]}"; do
  dir="terraform/environments/${env}"
  printf '\n\033[1m%s\033[0m\n' "$env"

  [ -d "$dir" ] || { echo "  no such environment"; continue; }
  [ -f "$dir/backend.conf" ] || { echo "  no backend.conf — not configured on this machine, skipping"; continue; }
  [ -f "$dir/terraform.tfvars" ] || { echo "  no terraform.tfvars — skipping"; continue; }

  ( cd "$dir" && terraform init -backend-config=backend.conf -input=false >/dev/null 2>&1 ) || {
    echo "  init failed"; overall=1; continue; }

  out=$(mktemp); set +e
  ( cd "$dir" && terraform plan -var-file=terraform.tfvars -input=false -no-color -detailed-exitcode ) >"$out" 2>&1
  code=$?
  set -e

  case "$code" in
    0) printf '  \033[32mno drift\033[0m — Azure matches the code\n' ;;
    2)
      adds=$(grep -cE '^  # .* will be created' "$out" || true)
      dels=$(grep -cE '^  # .* will be destroyed' "$out" || true)
      if [ "${dels:-0}" -eq 0 ] && [ "${adds:-0}" -gt 20 ]; then
        printf '  \033[36mnot deployed\033[0m — %s resources to create. This is an environment that has never been applied, or one that was decommissioned. It is not drift.\n' "$adds"
      else
        printf '  \033[33mCHANGES PENDING\033[0m — %s to add, %s to destroy. Run plan in %s.\n' "${adds:-?}" "${dels:-?}" "$dir"
        overall=2
      fi ;;
    *)
      if grep -q "Resource precondition failed\|not internally coherent" "$out"; then
        reason=$(grep -m1 -A1 "not internally coherent" "$out" | tail -1 | sed 's/^[[:space:]│]*//' || true)
        printf '  \033[35mrejected by a precondition\033[0m — %s\n' "${reason:-see plan output}"
      else
        printf '  \033[31mplan failed\033[0m (exit %s) — credentials or backend\n' "$code"
      fi
      overall=1 ;;
  esac
  rm -f "$out"
done

echo
case "$overall" in
  0) echo "No drift anywhere checked." ;;
  2) echo "Drift detected. A plan that shows changes nobody wrote is a change somebody made outside Terraform." ;;

  *) echo "At least one environment could not be checked." ;;
esac
exit "$overall"

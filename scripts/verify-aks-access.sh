#!/usr/bin/env bash
#
# verify-aks-access.sh — prove kubectl actually works, against the API.
#
# A green apply means Terraform is satisfied. It does not mean anyone can
# reach the cluster. This platform shipped a cluster NOBODY could enter and
# every tool reported it healthy:
#
#   - entra_admin_group_object_ids held a USER object ID. AKS binds that as a
#     Kubernetes GROUP subject, matched against the token's groups claim,
#     where a user's own object ID never appears. Valid GUID, accepted,
#     matched nobody.
#   - local accounts were disabled, so there was no fallback.
#   - Owner and Contributor carry dataActions: [], so full control of the
#     subscription grants no kubectl access whatsoever.
#
# Usage: scripts/verify-aks-access.sh <resource-group> <cluster-name>

set -euo pipefail

RG="${1:-}"; CLUSTER="${2:-}"
[ -n "$RG" ] && [ -n "$CLUSTER" ] || { echo "usage: $0 <resource-group> <cluster-name>" >&2; exit 2; }

KUBECONFIG_FILE="$(mktemp -t kubeconfig-verify.XXXXXX)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

az group exists -n "$RG" 2>/dev/null | grep -q true || {
  echo "resource group '$RG' does not exist in the current subscription." >&2
  echo "Nothing to verify. Access cannot be proven against a cluster that is not there." >&2
  exit 3; }

echo "Cluster configuration"
priv=$(az aks show -g "$RG" -n "$CLUSTER" --query apiServerAccessProfile.enablePrivateCluster -o tsv 2>/dev/null || echo "")
local_disabled=$(az aks show -g "$RG" -n "$CLUSTER" --query disableLocalAccounts -o tsv)
aad_rbac=$(az aks show -g "$RG" -n "$CLUSTER" --query aadProfile.enableAzureRbac -o tsv 2>/dev/null || echo "")
printf '  private cluster: %s | local accounts disabled: %s | azure rbac: %s\n' \
  "${priv:-false}" "$local_disabled" "${aad_rbac:-false}"

if [ "${priv}" = "true" ]; then
  echo "  NOTE: private cluster. get-credentials succeeds from anywhere and every"
  echo "        call after it times out unless you are inside the VNet."
fi

echo
echo "Cluster-scope RBAC"
cid=$(az aks show -g "$RG" -n "$CLUSTER" --query id -o tsv)
me=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
roles=$(az role assignment list --scope "$cid" --assignee "$me" --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)
if echo "$roles" | grep -q "RBAC Cluster Admin\|RBAC Admin\|RBAC Writer\|RBAC Reader"; then
  ok "data-plane role present: $(echo "$roles" | tr '\n' ' ')"
else
  bad "no Kubernetes data-plane role at cluster scope. Owner/Contributor do NOT count — they carry dataActions: []"
fi

echo
echo "Credentials"
az aks get-credentials -g "$RG" -n "$CLUSTER" --file "$KUBECONFIG_FILE" --overwrite-existing >/dev/null 2>&1
# -l azurecli reuses the existing az session; without it kubelogin defaults to
# devicecode and blocks on an interactive prompt.
if kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG_FILE" >/dev/null 2>&1; then
  ok "kubeconfig converted to azurecli mode (no device-code prompt)"
else
  bad "kubelogin convert-kubeconfig failed"
fi

echo
echo "Identity as the API server sees it"
if who=$(kubectl auth whoami 2>/dev/null); then
  while IFS= read -r l; do printf '  %s\n' "$l"; done <<<"$who"
  echo "  If an object ID sits in the cluster's admin GROUP list, look for it in"
  echo "  Groups above. If it only appears as Username, that binding matches nobody."
else
  bad "kubectl auth whoami failed — cannot reach the API server"
fi

echo
echo "Concrete permissions"
echo "  NOTE: 'kubectl auth can-i --list' is useless here. Azure RBAC is a webhook"
echo "        authorizer and cannot enumerate its rules, so the list looks empty"
echo "        even for a full admin. Test verbs instead."
for q in "get nodes" "get secrets --all-namespaces" "create deployments --namespace default" "delete namespaces"; do
  # shellcheck disable=SC2086
  r=$(kubectl auth can-i $q 2>/dev/null | tail -1 || echo "error")
  if [ "$r" = "yes" ]; then ok "can-i $q"; else bad "can-i $q -> $r"; fi
done

echo
echo "Real read"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /' || bad "kubectl get nodes failed"

echo
[ "$fail" -eq 0 ] && echo "Access verified against the API." || echo "Access is NOT proven."
exit "$fail"

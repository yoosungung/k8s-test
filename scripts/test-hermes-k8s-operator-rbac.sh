#!/usr/bin/env bash
# Pre-deploy validation for Hermes operator RBAC (TDD gate).
# Ensures cluster-wide read/monitoring stays future-proof as new CRDs are added.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RBAC_FILE="${ROOT_DIR}/manifests/infra/hermes-k8s-operator-rbac.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

assert_grep() {
  local pattern="$1"
  local message="$2"
  grep -Eq "${pattern}" "${RBAC_FILE}" || fail "${message}"
}

[[ -f "${RBAC_FILE}" ]] || fail "Missing ${RBAC_FILE}"

kubectl apply --dry-run=client -f "${RBAC_FILE}" >/dev/null
ok "RBAC manifest passes kubectl dry-run"

assert_grep 'apiGroups: \["\*"\]' "Missing wildcard apiGroups for cluster-wide monitoring"
assert_grep 'resources: \["\*"\]' "Missing wildcard resources for cluster-wide monitoring"
assert_grep 'verbs: \["get", "list", "watch"\]' "Missing get/list/watch monitoring verbs"
assert_grep 'pods/log' "Missing pods/log subresource for log monitoring"
assert_grep 'nodes/(proxy|stats|metrics)' "Missing kubelet stats subresources for disk monitoring"
assert_grep 'nonResourceURLs:' "Missing nonResourceURLs for API discovery"
assert_grep 'nebulaclusters' "Missing NebulaGraph nebulaclusters operational permissions"
assert_grep 'rbac\.authorization\.k8s\.io' "Missing RBAC read rules (Hermes must inspect bindings)"
ok "RBAC policy structure validated"

if grep -Eq 'rbac\.authorization\.k8s\.io' "${RBAC_FILE}" \
  && grep -A6 'rbac\.authorization\.k8s\.io' "${RBAC_FILE}" | grep -Eq 'verbs:.*(create|delete|update)'; then
  fail "RBAC write verbs must not be granted to Hermes"
fi
ok "RBAC privilege escalation guard validated"

if kubectl get sa hermes-master-sa -n ai-agents &>/dev/null; then
  SA="system:serviceaccount:ai-agents:hermes-master-sa"
  for resource in nebulaclusters.apps.nebula-graph.io customresourcedefinitions.apiextensions.k8s.io; do
    kubectl auth can-i list "${resource}" --as="${SA}" | grep -q yes \
      || fail "ServiceAccount cannot list ${resource} (apply RBAC to cluster: kubectl apply -f ${RBAC_FILE})"
  done
  ok "Live cluster auth can-i checks passed for Hermes SA"
else
  echo "[SKIP] ai-agents/hermes-master-sa not found; live auth checks skipped"
fi

ok "All Hermes operator RBAC tests passed"

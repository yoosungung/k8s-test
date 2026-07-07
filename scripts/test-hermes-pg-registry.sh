#!/usr/bin/env bash
# TDD gate: PostgreSQL instance registry convention and sync script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${ROOT_DIR}/helm/values/postgresql.yaml"
SYNC_SCRIPT="${ROOT_DIR}/scripts/sync-hermes-pg-registry.sh"
REGISTRY_DOC="${ROOT_DIR}/manifests/apps/hermes-pg-registry.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

[[ -f "${VALUES_FILE}" ]] || fail "Missing ${VALUES_FILE}"
[[ -x "${SYNC_SCRIPT}" ]] || fail "Missing executable ${SYNC_SCRIPT}"
[[ -f "${REGISTRY_DOC}" ]] || fail "Missing ${REGISTRY_DOC}"

grep -q 'k8s-test.io/postgres-instance' "${VALUES_FILE}" \
  || fail "postgresql.yaml must label instances with k8s-test.io/postgres-instance"
grep -q 'k8s-test.io/hermes-pg-config' "${VALUES_FILE}" \
  || fail "postgresql.yaml must opt in to Hermes config write with k8s-test.io/hermes-pg-config"
ok "PostgreSQL Helm values include Hermes discovery labels"

kubectl apply --dry-run=client -f "${REGISTRY_DOC}" >/dev/null
ok "Registry manifest passes kubectl dry-run"

# Offline validation: sync against a fixture when the cluster is unavailable.
FIXTURE="${ROOT_DIR}/scripts/fixtures/hermes-pg-services.json"
[[ -f "${FIXTURE}" ]] || fail "Missing fixture ${FIXTURE}"

REGISTRY_JSON="$("${SYNC_SCRIPT}" --input "${FIXTURE}" --dry-run)"
python3 - "${REGISTRY_JSON}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data.get("version") == 1, "registry version must be 1"
instances = data.get("instances")
assert isinstance(instances, list) and instances, "expected non-empty instances"
ids = {i["id"] for i in instances}
assert "postgres/postgresql" in ids, "fixture must include postgres/postgresql"
primary = next(i for i in instances if i["id"] == "postgres/postgresql")
assert primary["port"] == 5432
assert primary["configWritable"] is True
assert "postgresql" in primary.get("secrets", [])
assert "postgresql-init-scripts" in primary.get("configMaps", [])
# ingress TCP proxy must not be registered as a database.
assert not any(i["id"].startswith("ingress-nginx/") for i in instances)
print("fixture registry structure ok")
PY
ok "Sync script produces valid registry JSON from fixture"

if kubectl get ns ai-agents &>/dev/null; then
  "${SYNC_SCRIPT}"
  kubectl get configmap hermes-pg-registry -n ai-agents -o jsonpath='{.data.registry\.json}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["instances"], "live registry empty"'
  ok "Live cluster registry synced to ai-agents/hermes-pg-registry"
else
  echo "[SKIP] ai-agents namespace missing; live sync skipped"
fi

ok "All Hermes PostgreSQL registry tests passed"

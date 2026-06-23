#!/usr/bin/env bash
# Pre-deploy validation for NebulaGraph Studio manifest and ingress (TDD gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

MANIFEST="${ROOT_DIR}/manifests/apps/nebula-studio.yaml"
INGRESS="${ROOT_DIR}/manifests/apps/ingress-routes.yaml"
INGRESS_VALUES="${ROOT_DIR}/helm/values/ingress-nginx.yaml"

[[ -f "${MANIFEST}" ]] || fail "Missing ${MANIFEST}"

kubectl apply --dry-run=client -f "${MANIFEST}" >/dev/null
ok "nebula-studio manifest passes kubectl dry-run"

grep -q 'vesoft/nebula-graph-studio:v3.8.0' "${MANIFEST}" || fail "Expected Studio v3.8.0 image"
grep -q 'sqlite3' "${MANIFEST}" || fail "Expected sqlite3 DB backend (no external MySQL)"
grep -q 'namespace: nebula' "${MANIFEST}" || fail "Expected nebula namespace"
ok "Manifest contains expected Studio settings"

grep -q 'nebula-studio.k8s-test' "${INGRESS}" || fail "Expected nebula-studio.k8s-test ingress host"
grep -q 'nebula-studio' "${INGRESS}" || fail "Expected nebula-studio service in ingress-routes.yaml"
ok "Ingress route references nebula-studio"

grep -q '7001' "${INGRESS_VALUES}" || fail "Expected hostPort 7001 in ingress-nginx values"
grep -q 'socat TCP-LISTEN:7001' "${INGRESS_VALUES}" || fail "Expected socat listener on 7001"
ok "ingress-nginx exposes port 7001 for Studio"

ok "NebulaGraph Studio config validation passed"

#!/usr/bin/env bash
# Pre-deploy validation for Qdrant Helm values and namespace manifest (TDD gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

if ! command -v helm &>/dev/null; then
  fail "helm is required for Qdrant config tests"
fi

NS_FILE="${ROOT_DIR}/manifests/infra/qdrant-namespace.yaml"
VALUES_FILE="${ROOT_DIR}/helm/values/qdrant.yaml"
INGRESS="${ROOT_DIR}/manifests/apps/ingress-routes.yaml"
INGRESS_VALUES="${ROOT_DIR}/helm/values/ingress-nginx.yaml"

[[ -f "${NS_FILE}" ]] || fail "Missing ${NS_FILE}"
[[ -f "${VALUES_FILE}" ]] || fail "Missing ${VALUES_FILE}"
[[ -f "${INGRESS}" ]] || fail "Missing ${INGRESS}"
[[ -f "${INGRESS_VALUES}" ]] || fail "Missing ${INGRESS_VALUES}"

kubectl apply --dry-run=client -f "${NS_FILE}" >/dev/null
ok "Namespace manifest passes kubectl dry-run"

helm repo add qdrant https://qdrant.github.io/qdrant-helm 2>/dev/null || true
helm repo update qdrant >/dev/null

RENDERED="$(helm template qdrant qdrant/qdrant -f "${VALUES_FILE}")"
[[ -n "${RENDERED}" ]] || fail "helm template produced empty output"

echo "${RENDERED}" | grep -q 'kind: StatefulSet' || fail "Expected StatefulSet in rendered chart"
echo "${RENDERED}" | grep -q 'port: 6333' || fail "Expected REST port 6333 in rendered chart"
echo "${RENDERED}" | grep -q 'port: 6334' || fail "Expected gRPC port 6334 in rendered chart"
ok "Helm template renders StatefulSet with REST/gRPC ports"

grep -q 'qdrant.k8s-test' "${INGRESS}" || fail "Expected qdrant.k8s-test ingress host in ingress-routes.yaml"
grep -q 'name: qdrant' "${INGRESS}" || fail "Expected qdrant service in ingress-routes.yaml"
ok "Ingress route references qdrant"

grep -q 'socat TCP-LISTEN:6333' "${INGRESS_VALUES}" || fail "Expected socat listener on 6333 for HTTP ingress"
if grep -q '6333: "qdrant/qdrant:6333"' "${INGRESS_VALUES}"; then
  fail "Qdrant REST should use HTTP ingress (socat), not TCP passthrough on 6333"
fi
grep -q '6334: "qdrant/qdrant:6334"' "${INGRESS_VALUES}" || fail "Expected gRPC TCP passthrough on 6334"
ok "ingress-nginx routes Qdrant REST via HTTP ingress and gRPC via TCP"

ok "Qdrant config validation passed"

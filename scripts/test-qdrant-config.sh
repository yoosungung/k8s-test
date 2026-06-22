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

[[ -f "${NS_FILE}" ]] || fail "Missing ${NS_FILE}"
[[ -f "${VALUES_FILE}" ]] || fail "Missing ${VALUES_FILE}"

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

ok "Qdrant config validation passed"

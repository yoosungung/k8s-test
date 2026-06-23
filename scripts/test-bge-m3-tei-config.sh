#!/usr/bin/env bash
# Pre-deploy validation for BGE-M3 CPU TEI manifest (TDD gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

MANIFEST="${ROOT_DIR}/manifests/apps/bge-m3-tei.yaml"
INGRESS="${ROOT_DIR}/manifests/apps/ingress-routes.yaml"

[[ -f "${MANIFEST}" ]] || fail "Missing ${MANIFEST}"

kubectl apply --dry-run=client -f "${MANIFEST}" >/dev/null
ok "bge-m3-tei manifest passes kubectl dry-run"

grep -q 'BAAI/bge-m3' "${MANIFEST}" || fail "Expected model-id BAAI/bge-m3"
grep -q 'text-embeddings-inference:cpu-' "${MANIFEST}" || fail "Expected CPU TEI image"
grep -q 'max-batch-tokens' "${MANIFEST}" || fail "Expected --max-batch-tokens tuning flag"
grep -q '1024' "${MANIFEST}" || fail "Expected max-batch-tokens=1024 for ≤1k-token chunks"
grep -q 'nvidia.com/gpu' "${MANIFEST}" && fail "CPU TEI must not request GPU"
ok "Manifest contains expected CPU TEI optimization settings"

grep -q 'embeddings.k8s-test' "${INGRESS}" || fail "Expected embeddings.k8s-test ingress host in ingress-routes.yaml"
grep -q 'bge-m3-tei' "${INGRESS}" || fail "Expected bge-m3-tei service in ingress-routes.yaml"
ok "Ingress route references bge-m3-tei"

grep -q '8080' "${ROOT_DIR}/helm/values/ingress-nginx.yaml" || fail "Expected hostPort 8080 in ingress-nginx values"
ok "ingress-nginx exposes port 8080 for TEI"

ok "BGE-M3 TEI config validation passed"

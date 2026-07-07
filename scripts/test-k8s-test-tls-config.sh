#!/usr/bin/env bash
# Pre-deploy validation for *.k8s-test HTTPS on port 443 (TDD gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

INGRESS_VALUES="${ROOT_DIR}/helm/values/ingress-nginx.yaml"
INGRESS_ROUTES="${ROOT_DIR}/manifests/apps/ingress-routes.yaml"
SYNC_SCRIPT="${ROOT_DIR}/scripts/sync-k8s-test-tls-secret.sh"

[[ -f "${INGRESS_VALUES}" ]] || fail "Missing ${INGRESS_VALUES}"
[[ -f "${INGRESS_ROUTES}" ]] || fail "Missing ${INGRESS_ROUTES}"
[[ -x "${SYNC_SCRIPT}" ]] || fail "Missing executable ${SYNC_SCRIPT}"

helm template ingress-nginx ingress-nginx/ingress-nginx \
  -f "${INGRESS_VALUES}" >/dev/null 2>&1 \
  || helm template test ingress-nginx/ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    -f "${INGRESS_VALUES}" >/dev/null \
  || fail "ingress-nginx values fail helm template"

grep -q 'default-ssl-certificate' "${INGRESS_VALUES}" \
  || fail "Expected controller.extraArgs default-ssl-certificate in ingress-nginx values"
grep -q 'k8s-test-tls' "${INGRESS_VALUES}" \
  || fail "Expected k8s-test-tls secret reference in ingress-nginx values"
grep -q 'ssl-redirect' "${INGRESS_VALUES}" \
  || fail "Expected ssl-redirect in ingress-nginx controller config"
grep -q 'https: 443' "${INGRESS_VALUES}" \
  || fail "Expected hostPort https: 443 in ingress-nginx values"
ok "ingress-nginx values configure HTTPS default certificate on :443"

grep -q 'external-port-proxy' "${INGRESS_VALUES}" \
  && fail "Per-app socat sidecar must be removed (unified HTTPS :443)"
grep -q 'hostPort: 5173' "${INGRESS_VALUES}" \
  && fail "Per-app hostPort 5173 must be removed (unified HTTPS :443)"
grep -q 'hostPort: 8080' "${INGRESS_VALUES}" \
  && fail "Per-app hostPort 8080 must be removed (unified HTTPS :443)"
ok "ingress-nginx no longer exposes per-app HTTP hostPorts"

kubectl apply --dry-run=client -f "${INGRESS_ROUTES}" >/dev/null
ok "ingress-routes manifest passes kubectl dry-run"

for host in opik.k8s-test hermes.k8s-test hermes-api.k8s-test sglang.k8s-test embeddings.k8s-test; do
  grep -q "${host}" "${INGRESS_ROUTES}" || fail "Expected host ${host} in ingress-routes.yaml"
done
ok "ingress-routes lists expected *.k8s-test hosts"

grep -q 'K8S_TEST_TLS_SECRET_NAME' "${SYNC_SCRIPT}" \
  || fail "Expected K8S_TEST_TLS_SECRET_NAME in sync-k8s-test-tls-secret.sh"
grep -q 'k8s-test-tls' "${SYNC_SCRIPT}" \
  || fail "Expected k8s-test-tls secret name in sync script"

grep -q 'sync-k8s-test-tls-secret' "${ROOT_DIR}/scripts/deploy.sh" \
  || fail "deploy.sh must call sync-k8s-test-tls-secret.sh before ingress-nginx"
grep -q 'https://opik' "${ROOT_DIR}/scripts/deploy.sh" \
  || fail "deploy.sh log_ingress_routes must use https:// URLs"

ok "TLS sync script and deploy.sh integration present"
ok "*.k8s-test HTTPS config validation passed"

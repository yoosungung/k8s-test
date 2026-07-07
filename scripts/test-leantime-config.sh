#!/usr/bin/env bash
# Pre-deploy validation for Leantime + community MCP config (TDD gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

NAMESPACE_MANIFEST="${ROOT_DIR}/manifests/infra/leantime-namespace.yaml"
VALUES="${ROOT_DIR}/helm/values/leantime.yaml"
CHART_DIR="${ROOT_DIR}/helm/charts/leantime"
INGRESS_ROUTES="${ROOT_DIR}/manifests/apps/ingress-routes.yaml"
MCP_FIXTURE="${ROOT_DIR}/scripts/fixtures/leantime-mcp-cursor.json"
SYNC_CHART="${ROOT_DIR}/scripts/sync-leantime-chart.sh"
SMTP_SECRET_SYNC="${ROOT_DIR}/scripts/sync-leantime-smtp-secret.sh"
DEPLOY="${ROOT_DIR}/scripts/deploy.sh"
TEARDOWN="${ROOT_DIR}/scripts/teardown.sh"
VERIFY="${ROOT_DIR}/scripts/verify-leantime.sh"

[[ -f "${NAMESPACE_MANIFEST}" ]] || fail "Missing ${NAMESPACE_MANIFEST}"
[[ -f "${VALUES}" ]] || fail "Missing ${VALUES}"
[[ -f "${CHART_DIR}/Chart.yaml" ]] || fail "Missing ${CHART_DIR}/Chart.yaml (run ${SYNC_CHART})"
[[ -x "${SYNC_CHART}" ]] || fail "Missing executable ${SYNC_CHART}"
[[ -f "${MCP_FIXTURE}" ]] || fail "Missing ${MCP_FIXTURE}"
[[ -x "${VERIFY}" ]] || fail "Missing executable ${VERIFY}"

kubectl apply --dry-run=client -f "${NAMESPACE_MANIFEST}" >/dev/null
ok "leantime namespace manifest passes kubectl dry-run"

grep -q 'LEAN_APP_URL' "${CHART_DIR}/templates/deployment.yaml" \
  || fail "Leantime chart deployment must set LEAN_APP_URL for ingress HTTPS"
grep -q '^  url:' "${CHART_DIR}/values.yaml" \
  || fail "Leantime chart values must define app.url"

helm dependency build "${CHART_DIR}" >/dev/null
helm template leantime-test "${CHART_DIR}" -f "${VALUES}" \
  --set-string 'app.url=https://leantime.k8s-test' >/tmp/leantime-rendered.yaml \
  || fail "Leantime helm template failed"
grep -q 'memory_limit = 512M' /tmp/leantime-rendered.yaml \
  || fail "Expected PHP memory_limit=512M in rendered ConfigMap"
grep -q 'pm.max_children = 8' /tmp/leantime-rendered.yaml \
  || fail "Expected pm.max_children=8 in rendered ConfigMap"
grep -q 'secretKeyRef' /tmp/leantime-rendered.yaml \
  || fail "Expected SMTP password secretKeyRef in rendered deployment"
grep -q 'name: leantime-smtp' /tmp/leantime-rendered.yaml \
  || fail "Expected leantime-smtp secret reference in rendered deployment"
grep -q 'memory: 2Gi' "${VALUES}" \
  || fail "Expected 2Gi pod memory limit in values"
ok "Leantime chart renders with PHP-FPM tuning and 2Gi limit"

grep -q 'repository: leantime/leantime' "${VALUES}" \
  || fail "Expected leantime/leantime image in values"
grep -q 'tag:' "${VALUES}" \
  || fail "Expected pinned image tag in values"
grep -q 'bitnamilegacy/mariadb' "${VALUES}" \
  || fail "Expected bitnamilegacy/mariadb image override in values (Bitnami catalog brownout workaround)"
grep -q 'existingSecret: leantime-smtp' "${VALUES}" \
  || fail "Expected app.email.smtp.existingSecret in values"
if awk '/smtp:/{in_smtp=1} in_smtp && /^[^ ]/{if ($0 !~ /smtp:/) in_smtp=0} in_smtp && /password:/' "${VALUES}" | grep -q .; then
  fail "app.email.smtp.password must not be set in helm/values/leantime.yaml"
fi
[[ -x "${SMTP_SECRET_SYNC}" ]] || fail "Missing executable ${SMTP_SECRET_SYNC}"
ok "Leantime values pin image and configure MariaDB"

kubectl apply --dry-run=client -f "${INGRESS_ROUTES}" >/dev/null
grep -q 'leantime.k8s-test' "${INGRESS_ROUTES}" \
  || fail "Expected leantime.k8s-test host in ingress-routes.yaml"
grep -q 'namespace: leantime' "${INGRESS_ROUTES}" \
  || fail "Expected leantime namespace ingress in ingress-routes.yaml"
ok "ingress-routes includes leantime.k8s-test"

grep -q 'deploy_leantime' "${DEPLOY}" \
  || fail "deploy.sh must define deploy_leantime()"
grep -q 'sync-leantime-chart' "${DEPLOY}" \
  || fail "deploy.sh must ensure Leantime chart is synced"
grep -q 'sync-leantime-smtp-secret' "${DEPLOY}" \
  || fail "deploy.sh must sync Leantime SMTP secret"
grep -q 'leantime\.' "${DEPLOY}" \
  || fail "deploy.sh log_ingress_routes must mention leantime host"

grep -q 'helm uninstall leantime' "${TEARDOWN}" \
  || fail "teardown.sh must uninstall leantime helm release"
ok "deploy.sh and teardown.sh integrate Leantime"

grep -q 'daniel-eder/leantime-mcp' "${MCP_FIXTURE}" \
  || fail "MCP fixture must reference community leantime-mcp server"
grep -q 'LEANTIME_URL' "${MCP_FIXTURE}" \
  || fail "MCP fixture must set LEANTIME_URL"
grep -q 'LEANTIME_API_KEY' "${MCP_FIXTURE}" \
  || fail "MCP fixture must set LEANTIME_API_KEY"
ok "Community MCP Cursor fixture present"

bash "${SCRIPT_DIR}/test-leantime-files-browse-fix.sh"

grep -q 'Leantime' "${ROOT_DIR}/README.md" \
  || fail "README.md must document Leantime deployment"
grep -q 'leantime-mcp' "${ROOT_DIR}/README.md" \
  || fail "README.md must document community MCP setup"

ok "Leantime + community MCP config validation passed"

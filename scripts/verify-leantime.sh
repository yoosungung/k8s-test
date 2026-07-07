#!/usr/bin/env bash
# Post-deploy checks for Leantime (Helm) and community MCP readiness hints.
set -euo pipefail

NAMESPACE="${LEANTIME_NAMESPACE:-leantime}"
RELEASE="${LEANTIME_RELEASE:-leantime}"
SERVICE="${LEANTIME_SERVICE:-leantime}"
PORT="${LEANTIME_PORT:-80}"
INGRESS_HOST="${LEANTIME_INGRESS_HOST:-leantime.k8s-test}"
INGRESS_SCHEME="${LEANTIME_INGRESS_SCHEME:-https}"
INGRESS_PORT="${LEANTIME_INGRESS_PORT:-443}"
MCP_FIXTURE="${LEANTIME_MCP_FIXTURE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/fixtures/leantime-mcp-cursor.json}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "Context: $(kubectl config current-context)"

if ! helm status "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  fail "Helm release ${RELEASE} not found in namespace ${NAMESPACE}"
fi

echo "Waiting for ${RELEASE} deployment rollout..."
kubectl rollout status "deployment/${RELEASE}" -n "${NAMESPACE}" --timeout=600s

echo "Waiting for MariaDB StatefulSet..."
kubectl rollout status "statefulset/${RELEASE}-mariadb" -n "${NAMESPACE}" --timeout=600s

svc_url="http://${SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT}"
probe_pod() {
  local name="$1"
  shift
  kubectl run "${name}" --restart=Never \
    --image=curlimages/curl:8.12.1 \
    -n "${NAMESPACE}" \
    --command -- "$@" >/dev/null
  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${name}" \
    -n "${NAMESPACE}" --timeout=180s >/dev/null 2>&1; then
    kubectl logs "pod/${name}" -n "${NAMESPACE}" || true
    kubectl delete pod "${name}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
    fail "Probe pod ${name} did not succeed"
  fi
  kubectl logs "pod/${name}" -n "${NAMESPACE}"
  kubectl delete pod "${name}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
}

echo "Checking in-cluster HTTP..."
http_code="$(probe_pod leantime-http-check \
  curl -sS -o /dev/null -w '%{http_code}' "${svc_url}/")"
case "${http_code}" in
  200|301|302|303) ok "Leantime responds in-cluster (HTTP ${http_code}; 3xx often means /install redirect on first boot)" ;;
  *) fail "Unexpected HTTP ${http_code} from ${svc_url}/" ;;
esac

node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -n "${node_ip}" ]]; then
  ext_url="${INGRESS_SCHEME}://${node_ip}:${INGRESS_PORT}/"
  curl_opts=(-sf --max-time 30 -H "Host: ${INGRESS_HOST}")
  if [[ "${INGRESS_SCHEME}" == https ]]; then
    curl_opts+=(--insecure)
  fi
  if ext_code="$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "${ext_url}" 2>/dev/null)"; then
    ok "External ${INGRESS_SCHEME} reachable (HTTP ${ext_code}) at ${ext_url} (Host: ${INGRESS_HOST})"
  else
    warn "External ${ext_url} not reachable (add /etc/hosts: ${node_ip} ${INGRESS_HOST}; run sync-k8s-test-tls-secret.sh)"
  fi
fi

if [[ -f "${MCP_FIXTURE}" ]]; then
  ok "Community MCP fixture: ${MCP_FIXTURE}"
  echo ""
  echo "Next steps (free community MCP — no Marketplace plugin):"
  echo "  1. Open https://${INGRESS_HOST}/ and complete /install if first boot"
  echo "  2. Settings → Company → API Keys → generate key"
  echo "  3. brew install uv   # provides uvx"
  echo "  4. Copy ${MCP_FIXTURE} into Cursor MCP settings; set LEANTIME_API_KEY and LEANTIME_USER_EMAIL"
else
  warn "MCP fixture missing at ${MCP_FIXTURE}"
fi

ok "Leantime verification passed"

#!/usr/bin/env bash
# Post-deploy checks for NebulaGraph Studio web GUI.
set -euo pipefail

NAMESPACE="${NEBULA_STUDIO_NAMESPACE:-nebula}"
DEPLOY="${NEBULA_STUDIO_DEPLOY:-nebula-studio}"
SERVICE="${NEBULA_STUDIO_SERVICE:-nebula-studio}"
PORT="${NEBULA_STUDIO_PORT:-7001}"
INGRESS_HOST="${NEBULA_STUDIO_INGRESS_HOST:-nebula-studio.k8s-test}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "Context: $(kubectl config current-context)"
echo "Waiting for ${DEPLOY} rollout..."
kubectl rollout status "deployment/${DEPLOY}" -n "${NAMESPACE}" --timeout=300s

svc_url="http://${SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT}"
kubectl run nebula-studio-health-check --rm -i --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -n "${NAMESPACE}" \
  --command -- \
  curl -fsS "${svc_url}/" >/dev/null
ok "Studio HTTP responds in-cluster"

node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -n "${node_ip}" ]]; then
  ext_url="http://${node_ip}:${PORT}/"
  if curl -sf --max-time 15 -H "Host: ${INGRESS_HOST}" "${ext_url}" >/dev/null 2>&1; then
    ok "External HTTP reachable at ${ext_url} (Host: ${INGRESS_HOST})"
  else
    warn "External ${ext_url} not reachable from this host (set /etc/hosts: ${node_ip} ${INGRESS_HOST})"
  fi
fi

ok "NebulaGraph Studio verification passed"

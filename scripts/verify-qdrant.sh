#!/usr/bin/env bash
# Post-deploy checks for Qdrant vector database.
set -euo pipefail

QDRANT_NAMESPACE="${QDRANT_NAMESPACE:-qdrant}"
QDRANT_RELEASE="${QDRANT_RELEASE:-qdrant}"
QDRANT_API_KEY="${QDRANT_API_KEY:-test-qdrant-api-key}"
QDRANT_REST_PORT="${QDRANT_REST_PORT:-6333}"
QDRANT_INGRESS_HOST="${QDRANT_INGRESS_HOST:-qdrant.k8s-test}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "Context: $(kubectl config current-context)"
echo "Waiting for Qdrant StatefulSet rollout..."
kubectl rollout status "statefulset/${QDRANT_RELEASE}" -n "${QDRANT_NAMESPACE}" --timeout=300s

pod="${QDRANT_RELEASE}-0"
kubectl wait --for=condition=Ready "pod/${pod}" -n "${QDRANT_NAMESPACE}" --timeout=180s
ok "Pod ${pod} is Ready"

echo "Checking in-cluster REST health..."
kubectl run qdrant-health-check --rm -i --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -n "${QDRANT_NAMESPACE}" \
  --command -- \
  curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
  "http://${QDRANT_RELEASE}.${QDRANT_NAMESPACE}.svc.cluster.local:${QDRANT_REST_PORT}/collections" \
  >/dev/null
ok "REST /collections responds with api-key"

node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -n "${node_ip}" ]]; then
  if curl -fsS -m 5 -H "api-key: ${QDRANT_API_KEY}" -H "Host: ${QDRANT_INGRESS_HOST}" \
    "http://${node_ip}:${QDRANT_REST_PORT}/collections" >/dev/null 2>&1; then
    ok "External REST via ingress on ${node_ip}:${QDRANT_REST_PORT} (Host: ${QDRANT_INGRESS_HOST})"
  else
    warn "External REST on ${node_ip}:${QDRANT_REST_PORT} not reachable (set /etc/hosts: ${node_ip} ${QDRANT_INGRESS_HOST})"
  fi
fi

ok "Qdrant verification passed"

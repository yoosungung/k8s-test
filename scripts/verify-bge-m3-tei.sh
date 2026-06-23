#!/usr/bin/env bash
# Post-deploy checks for BGE-M3 CPU Text Embeddings Inference.
set -euo pipefail

NAMESPACE="${BGE_M3_TEI_NAMESPACE:-llm-serving}"
DEPLOY="${BGE_M3_TEI_DEPLOY:-bge-m3-tei}"
SERVICE="${BGE_M3_TEI_SERVICE:-bge-m3-tei}"
PORT="${BGE_M3_TEI_PORT:-8080}"
MODEL="${BGE_M3_TEI_MODEL:-BAAI/bge-m3}"
EXPECTED_DIM="${BGE_M3_EXPECTED_DIM:-1024}"
INGRESS_HOST="${BGE_M3_TEI_INGRESS_HOST:-embeddings.k8s-test}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "Context: $(kubectl config current-context)"
echo "Waiting for ${DEPLOY} rollout..."
kubectl rollout status "deployment/${DEPLOY}" -n "${NAMESPACE}" --timeout=600s

svc_url="http://${SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT}"
probe_pod() {
  local name="$1"
  shift
  kubectl run "${name}" --restart=Never \
    --image=curlimages/curl:8.12.1 \
    -n "${NAMESPACE}" \
    --command -- "$@" >/dev/null
  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${name}" \
    -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1; then
    kubectl logs "pod/${name}" -n "${NAMESPACE}" || true
    kubectl delete pod "${name}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
    fail "Probe pod ${name} did not succeed"
  fi
  kubectl logs "pod/${name}" -n "${NAMESPACE}"
  kubectl delete pod "${name}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
}

echo "Checking in-cluster /health..."
probe_pod bge-m3-tei-health-check curl -fsS "${svc_url}/health" >/dev/null
ok "GET /health responds in-cluster"

echo "Checking in-cluster /v1/embeddings..."
embed_json="$(probe_pod bge-m3-tei-embed-check \
  curl -fsS "${svc_url}/v1/embeddings" \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"${MODEL}\", \"input\": \"hello world\"}")"

python3 - "${embed_json}" "${EXPECTED_DIM}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected = int(sys.argv[2])
data = payload.get("data") or []
if not data:
    raise SystemExit("FAIL: empty embedding data")
vec = data[0].get("embedding") or []
if len(vec) != expected:
    raise SystemExit(f"FAIL: expected dim {expected}, got {len(vec)}")
print(f"embedding dim={len(vec)}")
PY
ok "Dense embedding dimension is ${EXPECTED_DIM}"

node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -n "${node_ip}" ]]; then
  ext_url="http://${node_ip}:${PORT}/v1/embeddings"
  if curl -sf --max-time 30 -H "Host: ${INGRESS_HOST}" \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"${MODEL}\", \"input\": \"hello\"}" \
    "${ext_url}" >/dev/null 2>&1; then
    ok "External HTTP reachable at ${ext_url} (Host: ${INGRESS_HOST})"
  else
    warn "External ${ext_url} not reachable from this host (set /etc/hosts: ${node_ip} ${INGRESS_HOST})"
  fi
fi

ok "BGE-M3 TEI verification passed"

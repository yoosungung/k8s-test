#!/usr/bin/env bash
# Reproduce Leantime /files/browse memory failure inside the running pod.
set -euo pipefail

NAMESPACE="${LEANTIME_NAMESPACE:-leantime}"
ROUTE="${1:-files/browse}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/diagnose-leantime-files-browse.php"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

POD="$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=leantime -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${POD}" ]] || fail "No leantime pod in namespace ${NAMESPACE}"

log "Pod: ${POD}"
log "Route: /${ROUTE}"

REMOTE="/tmp/diagnose-leantime-files-browse.php"
kubectl cp "${LIB}" "${NAMESPACE}/${POD}:${REMOTE}" >/dev/null

echo "--- in-pod diagnostic ---"
if ! kubectl exec -n "${NAMESPACE}" "${POD}" -- php "${REMOTE}" "${ROUTE}" 2>&1; then
  rc=$?
  warn "Diagnostic exited ${rc}"
fi

echo "--- recent pod logs (memory/fatal) ---"
kubectl logs -n "${NAMESPACE}" "${POD}" --tail=15 2>/dev/null | grep -E 'memory|Fatal|SIGSEGV|files/browse' || true

echo "--- compare routes ---"
for r in tickets/showKanban reports/show "${ROUTE}"; do
  code="$(kubectl exec -n "${NAMESPACE}" "${POD}" -- curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/${r}" 2>/dev/null || echo err)"
  echo "  GET /${r} -> HTTP ${code} (unauthenticated)"
done

log "Done. For authenticated curl, log in via browser and copy leantime_session cookie."

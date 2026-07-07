#!/usr/bin/env bash
# Discover every in-cluster Service on TCP :5432 and publish a Hermes registry ConfigMap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILDER="${SCRIPT_DIR}/lib/build-hermes-pg-registry.py"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-ai-agents}"
REGISTRY_NAME="${REGISTRY_NAME:-hermes-pg-registry}"
INPUT_JSON=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sync-hermes-pg-registry.sh [--dry-run] [--input services.json]

  --dry-run   Print registry JSON to stdout; do not apply ConfigMap.
  --input     Use a kubectl List JSON fixture instead of live cluster discovery.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --input) INPUT_JSON="${2:?--input requires a file}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -f "${BUILDER}" ]] || { echo "Missing ${BUILDER}" >&2; exit 1; }

if [[ -n "${INPUT_JSON}" ]]; then
  REGISTRY_JSON="$(python3 "${BUILDER}" --input "${INPUT_JSON}")"
else
  if ! command -v kubectl &>/dev/null; then
    echo "kubectl is required unless --input is provided" >&2
    exit 1
  fi
  REGISTRY_JSON="$(python3 "${BUILDER}" --live)"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "${REGISTRY_JSON}"
  exit 0
fi

kubectl create configmap "${REGISTRY_NAME}" \
  --namespace "${REGISTRY_NAMESPACE}" \
  --from-literal=registry.json="${REGISTRY_JSON}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "Synced ${REGISTRY_NAMESPACE}/${REGISTRY_NAME} with $(echo "${REGISTRY_JSON}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["instances"]))') PostgreSQL endpoint(s)"

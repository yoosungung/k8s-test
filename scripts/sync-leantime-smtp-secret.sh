#!/usr/bin/env bash
# Create or update Leantime SMTP password Secret (never store in Helm values).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LEANTIME_SMTP_SECRET_NAME="${LEANTIME_SMTP_SECRET_NAME:-leantime-smtp}"
LEANTIME_SMTP_SECRET_KEY="${LEANTIME_SMTP_SECRET_KEY:-password}"
LEANTIME_NAMESPACE="${LEANTIME_NAMESPACE:-leantime}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0")

Creates or updates Secret '${LEANTIME_SMTP_SECRET_NAME}' in namespace '${LEANTIME_NAMESPACE}'.

Set the Gmail app password (or other SMTP password) via environment variable:
  LEANTIME_SMTP_PASSWORD='your-app-password' $(basename "$0")

If the secret already exists and LEANTIME_SMTP_PASSWORD is unset, the secret is left unchanged.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl is required."
    exit 1
fi

password="${LEANTIME_SMTP_PASSWORD:-}"

if [[ -z "${password}" ]] && kubectl get secret "${LEANTIME_SMTP_SECRET_NAME}" -n "${LEANTIME_NAMESPACE}" &>/dev/null; then
    log_info "Secret ${LEANTIME_SMTP_SECRET_NAME} already exists in ${LEANTIME_NAMESPACE}; leaving unchanged."
    exit 0
fi

if [[ -z "${password}" ]]; then
    log_error "LEANTIME_SMTP_PASSWORD is required (secret ${LEANTIME_SMTP_SECRET_NAME} not found)."
    usage
    exit 1
fi

kubectl create namespace "${LEANTIME_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log_info "Applying SMTP secret ${LEANTIME_SMTP_SECRET_NAME} in ${LEANTIME_NAMESPACE}..."
kubectl create secret generic "${LEANTIME_SMTP_SECRET_NAME}" \
    --namespace "${LEANTIME_NAMESPACE}" \
    --from-literal="${LEANTIME_SMTP_SECRET_KEY}=${password}" \
    --dry-run=client -o yaml | kubectl apply -f -

log_info "SMTP secret ready."

#!/usr/bin/env bash
# Upload mkcert *.k8s-test certificate to ingress-nginx as TLS Secret.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

K8S_TEST_TLS_SECRET_NAME="${K8S_TEST_TLS_SECRET_NAME:-k8s-test-tls}"
K8S_TEST_TLS_NAMESPACE="${K8S_TEST_TLS_NAMESPACE:-ingress-nginx}"
K8S_TEST_TLS_DIR="${K8S_TEST_TLS_DIR:-${ROOT_DIR}/.certs}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

resolve_cert_paths() {
    if [[ -n "${K8S_TEST_TLS_CERT:-}" && -n "${K8S_TEST_TLS_KEY:-}" ]]; then
        CERT_PATH="${K8S_TEST_TLS_CERT}"
        KEY_PATH="${K8S_TEST_TLS_KEY}"
        return 0
    fi

    CERT_PATH="$(find "${K8S_TEST_TLS_DIR}" -maxdepth 1 -type f -name '*k8s-test*.pem' ! -name '*-key.pem' 2>/dev/null | head -1 || true)"
    KEY_PATH="$(find "${K8S_TEST_TLS_DIR}" -maxdepth 1 -type f -name '*k8s-test*-key.pem' 2>/dev/null | head -1 || true)"

    if [[ -z "${CERT_PATH}" || -z "${KEY_PATH}" ]]; then
        return 1
    fi
    return 0
}

usage() {
    cat <<EOF
Usage: $(basename "$0")

Creates or updates TLS secret '${K8S_TEST_TLS_SECRET_NAME}' in namespace '${K8S_TEST_TLS_NAMESPACE}'.

Certificate sources (first match wins):
  1. K8S_TEST_TLS_CERT + K8S_TEST_TLS_KEY environment variables
  2. mkcert files under \${K8S_TEST_TLS_DIR} (default: ${ROOT_DIR}/.certs)

Generate certs (Mac, one-time):
  brew install mkcert nss
  mkcert -install
  mkdir -p ${ROOT_DIR}/.certs
  cd ${ROOT_DIR}/.certs && mkcert "*.k8s-test"

Skip during deploy: SKIP_K8S_TEST_TLS=true ./scripts/deploy.sh --force
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

if ! resolve_cert_paths; then
    log_error "mkcert TLS files not found."
    usage
    exit 1
fi

cert_file="${CERT_PATH}"
key_file="${KEY_PATH}"

[[ -f "${cert_file}" ]] || { log_error "Certificate not found: ${cert_file}"; exit 1; }
[[ -f "${key_file}" ]] || { log_error "Private key not found: ${key_file}"; exit 1; }

kubectl create namespace "${K8S_TEST_TLS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log_info "Applying TLS secret ${K8S_TEST_TLS_SECRET_NAME} in ${K8S_TEST_TLS_NAMESPACE}..."
kubectl create secret tls "${K8S_TEST_TLS_SECRET_NAME}" \
    --namespace "${K8S_TEST_TLS_NAMESPACE}" \
    --cert="${cert_file}" \
    --key="${key_file}" \
    --dry-run=client -o yaml | kubectl apply -f -

log_info "TLS secret ready (cert: ${cert_file})."

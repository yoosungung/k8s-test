#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# or if any undefined variable is referenced.
set -euo pipefail

# Color codes for formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]$(date +'%Y-%m-%d %H:%M:%S') $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN]$(date +'%Y-%m-%d %H:%M:%S') $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR]$(date +'%Y-%m-%d %H:%M:%S') $1${NC}"
}

# Resolve script directory to allow running this script from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log_info "Verifying prerequisites..."

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed. Exiting."
    exit 1
fi

# Check helm
if ! command -v helm &> /dev/null; then
    log_warn "helm is not installed. Helm chart teardown will be skipped."
    HAS_HELM=false
else
    HAS_HELM=true
fi

# Print active context
CURRENT_CONTEXT=$(kubectl config current-context)
log_warn "WARNING: You are about to tear down resources in context: ${CURRENT_CONTEXT}"

# Prompt confirmation (optional, set to non-interactive check)
if [[ "${1:-}" != "--force" ]]; then
    read -p "Are you absolutely sure you want to clean up all test resources in [${CURRENT_CONTEXT}]? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Teardown cancelled by user."
        exit 0
    fi
fi

# 1. Teardown Application Manifests (First, to release dependencies cleanly)
log_info "Deleting application manifests..."
APPS_DIR="${ROOT_DIR}/manifests/apps"
if [ -d "${APPS_DIR}" ] && [ "$(ls -A "${APPS_DIR}")" ]; then
    find "${APPS_DIR}" -name "*.yaml" -o -name "*.yml" | while read -r yaml_file; do
        log_info "Deleting: $(basename "${yaml_file}")"
        kubectl delete --ignore-not-found -f "${yaml_file}"
    done
else
    log_warn "No application manifests found to delete."
fi

# 2. Teardown Helm Releases
if [ "$HAS_HELM" = true ]; then
    log_info "Deleting Helm releases..."
    log_info "Uninstalling Opik Helm release..."
    if kubectl get chi opik-clickhouse -n opik &> /dev/null; then
        log_info "Removing ClickHouse finalizer before Opik uninstall..."
        kubectl patch -n opik chi opik-clickhouse --type json \
            --patch='[{ "op": "remove", "path": "/metadata/finalizers" }]' || true
    fi
    helm uninstall opik --namespace opik || true
    log_info "Uninstalling Leantime Helm release..."
    helm uninstall leantime --namespace leantime || true
    log_info "Uninstalling PostgreSQL Helm release..."
    helm uninstall postgresql --namespace postgres || true
    log_info "Uninstalling git-http-server Helm release..."
    helm uninstall git-http-server --namespace git || true
    log_info "Uninstalling ingress-nginx Helm release..."
    helm uninstall ingress-nginx --namespace ingress-nginx || true
fi

# 2.5 Delete manually created secrets
log_info "Deleting standalone secrets..."
kubectl delete secret hf-token-secret -n llm-serving --ignore-not-found || true
kubectl delete secret hermes-gateway-secrets -n ai-agents --ignore-not-found || true
kubectl delete secret hermes-auth-secrets -n ai-agents --ignore-not-found || true
kubectl delete secret k8s-test-tls -n ingress-nginx --ignore-not-found || true
kubectl delete secret git-http-auth -n git --ignore-not-found || true

# 2.7 Delete cluster-scoped RBAC resources (not tied to any namespace)
log_info "Deleting cluster-scoped RBAC resources..."
kubectl delete clusterrolebinding hermes-k8s-manager-binding --ignore-not-found || true
kubectl delete clusterrole hermes-k8s-manager-role --ignore-not-found || true


# 3. Teardown Infrastructure Manifests
log_info "Deleting infrastructure manifests..."
INFRA_DIR="${ROOT_DIR}/manifests/infra"
if [ -d "${INFRA_DIR}" ] && [ "$(ls -A "${INFRA_DIR}")" ]; then
    find "${INFRA_DIR}" -name "*.yaml" -o -name "*.yml" | while read -r yaml_file; do
        if [[ "$(basename "${yaml_file}")" != *namespace.yaml && "$(basename "${yaml_file}")" != *namespace.yml ]]; then
            log_info "Deleting: $(basename "${yaml_file}")"
            kubectl delete --ignore-not-found -f "${yaml_file}" || true
        fi
    done
    # Delete namespaces last to ensure all child resources are cleaned up first
    find "${INFRA_DIR}" -name "*namespace.yaml" -o -name "*namespace.yml" | while read -r ns_file; do
        log_info "Deleting namespace: $(basename "${ns_file}")"
        kubectl delete --ignore-not-found -f "${ns_file}" || true
    done
else
    log_warn "No infrastructure manifests found to delete."
fi

log_info "Teardown sequence completed!"

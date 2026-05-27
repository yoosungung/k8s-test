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
    log_warn "helm is not installed. Helm chart installations will be skipped."
    HAS_HELM=false
else
    HAS_HELM=true
fi

# Print active context
CURRENT_CONTEXT=$(kubectl config current-context)
log_info "Current Kubernetes Context: ${CURRENT_CONTEXT}"

# Prompt confirmation (optional, set to non-interactive check)
if [[ "${1:-}" != "--force" ]]; then
    read -p "Do you want to deploy to [${CURRENT_CONTEXT}]? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Deployment cancelled by user."
        exit 0
    fi
fi

# 1. Create Core Namespaces
log_info "Applying namespaces..."
find "${ROOT_DIR}/manifests/infra" -name "*namespace.yaml" -o -name "*namespace.yml" | while read -r ns_file; do
    log_info "Applying namespace: $(basename "${ns_file}")"
    kubectl apply -f "${ns_file}"
done

# 2. Deploy Infrastructure Manifests
log_info "Applying infrastructure manifests..."
INFRA_DIR="${ROOT_DIR}/manifests/infra"
if [ -d "${INFRA_DIR}" ] && [ "$(ls -A "${INFRA_DIR}")" ]; then
    find "${INFRA_DIR}" -name "*.yaml" -o -name "*.yml" | while read -r yaml_file; do
        if [[ "$(basename "${yaml_file}")" != *namespace.yaml && "$(basename "${yaml_file}")" != *namespace.yml ]]; then
            log_info "Applying: $(basename "${yaml_file}")"
            kubectl apply -f "${yaml_file}"
        fi
    done
else
    log_warn "No infrastructure manifests found under ${INFRA_DIR}."
fi

# 3. Install/Upgrade Helm Charts
if [ "$HAS_HELM" = true ]; then
    log_info "Deploying Helm releases..."
    log_info "Ensuring Bitnami Helm repo is registered..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update
    
    log_info "Installing/upgrading PostgreSQL release in namespace 'postgres'..."
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace postgres \
        --create-namespace \
        -f "${ROOT_DIR}/helm/values/postgresql.yaml"
fi

# 3.5 Set up Hugging Face Token Secret if needed
log_info "Checking Hugging Face token secret..."
if ! kubectl get secret hf-token-secret -n llm-serving &> /dev/null; then
    if [ -n "${HF_TOKEN:-}" ]; then
        log_info "Creating hf-token-secret using HF_TOKEN environment variable..."
        kubectl create secret generic hf-token-secret -n llm-serving --from-literal=token="${HF_TOKEN}"
    elif [[ "${1:-}" != "--force" ]] && [ -t 0 ]; then
        echo -e "${YELLOW}[PROMPT] Hugging Face token secret not found.${NC}"
        read -rsp "Please enter your Hugging Face Token (leave empty to use placeholder): " hf_token_input
        echo ""
        if [ -n "${hf_token_input}" ]; then
            log_info "Creating hf-token-secret with provided token..."
            kubectl create secret generic hf-token-secret -n llm-serving --from-literal=token="${hf_token_input}"
        else
            log_warn "No token entered. Applying default placeholder secret..."
            kubectl apply -f "${ROOT_DIR}/manifests/apps/hf-secret.yaml"
        fi
    else
        log_warn "Running in non-interactive/forced mode. Applying default placeholder secret..."
        kubectl apply -f "${ROOT_DIR}/manifests/apps/hf-secret.yaml"
    fi
else
    log_info "hf-token-secret already exists in 'llm-serving' namespace."
fi

# 4. Deploy Application Manifests
log_info "Applying application manifests..."
APPS_DIR="${ROOT_DIR}/manifests/apps"
if [ -d "${APPS_DIR}" ] && [ "$(ls -A "${APPS_DIR}")" ]; then
    find "${APPS_DIR}" -name "*.yaml" -o -name "*.yml" | while read -r yaml_file; do
        if [ "$(basename "${yaml_file}")" != "hf-secret.yaml" ]; then
            log_info "Applying: $(basename "${yaml_file}")"
            kubectl apply -f "${yaml_file}"
        fi
    done
else
    log_warn "No application manifests found under ${APPS_DIR}."
fi

log_info "Deployment sequence completed successfully!"

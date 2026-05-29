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

HERMES_SECRET_NAME="hermes-gateway-secrets"
HERMES_NAMESPACE="ai-agents"
HERMES_DEFAULT_DISCORD_ALLOWED_USERS="ericberryking"

apply_hermes_gateway_secret() {
    local discord_token="$1"
    local openai_key="$2"
    local api_server_key="$3"
    local discord_allowed_users="${4:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}"

    kubectl create secret generic "${HERMES_SECRET_NAME}" \
        --namespace "${HERMES_NAMESPACE}" \
        --from-literal=DISCORD_BOT_TOKEN="${discord_token}" \
        --from-literal=OPENAI_API_KEY="${openai_key}" \
        --from-literal=HERMES_API_SERVER_KEY="${api_server_key}" \
        --from-literal=DISCORD_ALLOWED_USERS="${discord_allowed_users}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

generate_hermes_api_server_key() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 32
    else
        # Fallback when openssl is unavailable (API key must be >= 8 chars)
        date +%s | shasum -a 256 | cut -c1-32
    fi
}

ensure_pgvector_extension() {
    local namespace="postgres"
    local statefulset_name="postgresql"
    local pod_name="postgresql-0"
    local target_db="hermesdb"

    log_info "Waiting for PostgreSQL rollout to ensure pgvector is enabled..."
    kubectl rollout status statefulset/"${statefulset_name}" -n "${namespace}" --timeout=180s
    kubectl wait --for=condition=Ready pod/"${pod_name}" -n "${namespace}" --timeout=180s

    log_info "Ensuring pgvector extension exists in database '${target_db}'..."
    if kubectl exec -n "${namespace}" "${pod_name}" -- /bin/bash -lc \
        "export PGPASSWORD=\"\${POSTGRES_PASSWORD}\" && psql -v ON_ERROR_STOP=1 -U postgres -d \"${target_db}\" -c 'CREATE EXTENSION IF NOT EXISTS vector;'"; then
        log_info "pgvector extension is enabled in '${target_db}'."
    else
        log_warn "Failed to enable pgvector automatically. Check PostgreSQL image compatibility and run CREATE EXTENSION manually."
    fi
}

# Resolve script directory to allow running this script from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERMES_SECRETS_PLACEHOLDER="${ROOT_DIR}/manifests/apps/hermes-gateway-secrets.yaml"

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

    ensure_pgvector_extension
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

# 3.6 Set up Hermes gateway secrets if needed
log_info "Checking Hermes gateway secret..."
if ! kubectl get secret "${HERMES_SECRET_NAME}" -n "${HERMES_NAMESPACE}" &> /dev/null; then
    if [ -n "${OPENAI_API_KEY:-}" ] && [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
        hermes_api_key="${HERMES_API_SERVER_KEY:-}"
        if [ -z "${hermes_api_key}" ]; then
            hermes_api_key="$(generate_hermes_api_server_key)"
            log_info "HERMES_API_SERVER_KEY not set; generated a new key."
        fi
        log_info "Creating ${HERMES_SECRET_NAME} from environment variables..."
        apply_hermes_gateway_secret \
            "${DISCORD_BOT_TOKEN}" \
            "${OPENAI_API_KEY}" \
            "${hermes_api_key}" \
            "${DISCORD_ALLOWED_USERS:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}"
    elif [[ "${1:-}" != "--force" ]] && [ -t 0 ]; then
        echo -e "${YELLOW}[PROMPT] Hermes gateway secret not found.${NC}"
        read -rsp "OpenAI API key (OPENAI_API_KEY): " openai_key_input
        echo ""
        if [ -z "${openai_key_input}" ]; then
            log_warn "OpenAI API key is required. Applying placeholder secret..."
            kubectl apply -f "${HERMES_SECRETS_PLACEHOLDER}"
        else
            read -rsp "Discord bot token (leave empty for placeholder): " discord_token_input
            echo ""
            if [ -z "${discord_token_input}" ]; then
                discord_token_input="REPLACE_WITH_DISCORD_BOT_TOKEN"
            fi
            read -rsp "Hermes API server key (leave empty to auto-generate): " api_server_key_input
            echo ""
            if [ -z "${api_server_key_input}" ]; then
                api_server_key_input="$(generate_hermes_api_server_key)"
                log_info "Generated HERMES_API_SERVER_KEY."
            fi
            read -rp "Discord allowed users [${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}]: " discord_users_input
            log_info "Creating ${HERMES_SECRET_NAME} with provided values..."
            apply_hermes_gateway_secret \
                "${discord_token_input}" \
                "${openai_key_input}" \
                "${api_server_key_input}" \
                "${discord_users_input:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}"
        fi
    else
        log_warn "Running in non-interactive/forced mode without Hermes env vars. Applying placeholder secret..."
        kubectl apply -f "${HERMES_SECRETS_PLACEHOLDER}"
    fi
else
    log_info "${HERMES_SECRET_NAME} already exists in '${HERMES_NAMESPACE}' namespace."
fi

# 3.7 Set up Hermes auth secrets if needed
log_info "Checking Hermes auth secrets..."
if ! kubectl get secret "hermes-auth-secrets" -n "${HERMES_NAMESPACE}" &> /dev/null; then
    if [ -f "${HOME}/.hermes/auth.json" ]; then
        log_info "Creating hermes-auth-secrets from local ~/.hermes/auth.json..."
        kubectl create secret generic hermes-auth-secrets \
            --namespace "${HERMES_NAMESPACE}" \
            --from-file=auth.json="${HOME}/.hermes/auth.json"
    else
        log_warn "Local ~/.hermes/auth.json not found. Skipping hermes-auth-secrets creation."
    fi
else
    log_info "hermes-auth-secrets already exists in '${HERMES_NAMESPACE}' namespace."
fi

# 4. Deploy Application Manifests
log_info "Applying application manifests..."
APPS_DIR="${ROOT_DIR}/manifests/apps"
if [ -d "${APPS_DIR}" ] && [ "$(ls -A "${APPS_DIR}")" ]; then
    find "${APPS_DIR}" -name "*.yaml" -o -name "*.yml" | while read -r yaml_file; do
        base_name="$(basename "${yaml_file}")"
        if [ "${base_name}" != "hf-secret.yaml" ] \
            && [ "${base_name}" != "hermes-gateway-secrets.yaml" ] \
            && [ "${base_name}" != "hermes-initial-subagents.yaml" ]; then
            log_info "Applying: $(basename "${yaml_file}")"
            kubectl apply -f "${yaml_file}"
        fi
    done
else
    log_warn "No application manifests found under ${APPS_DIR}."
fi

log_info "Deployment sequence completed successfully!"

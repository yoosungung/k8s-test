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

OPIK_NAMESPACE="opik"
OPIK_RELEASE="opik"
OPIK_VERSION="${OPIK_VERSION:-latest}"

LEANTIME_NAMESPACE="leantime"
LEANTIME_RELEASE="leantime"
LEANTIME_VERSION="${LEANTIME_VERSION:-3.9.7}"
LEANTIME_SMTP_SECRET_NAME="${LEANTIME_SMTP_SECRET_NAME:-leantime-smtp}"

INGRESS_NAMESPACE="ingress-nginx"
INGRESS_RELEASE="ingress-nginx"
INGRESS_HTTP_NODEPORT="80"
INGRESS_HTTPS_NODEPORT="443"
POSTGRES_TCP_NODEPORT="5432"
OPIK_HTTP_PORT="5173"
SGLANG_HTTP_PORT="30000"
BGE_M3_TEI_HTTP_PORT="8080"
NEBULA_STUDIO_HTTP_PORT="7001"
HERMES_DASHBOARD_PORT="9119"
HERMES_API_PORT="8642"

GIT_HTTP_NAMESPACE="git"
GIT_HTTP_RELEASE="git-http-server"
GIT_HTTP_AUTH_SECRET="git-http-auth"
K8S_TEST_DOMAIN_SUFFIX="${K8S_TEST_DOMAIN_SUFFIX:-k8s-test}"
LEANTIME_INGRESS_HOST="${LEANTIME_INGRESS_HOST:-leantime.${K8S_TEST_DOMAIN_SUFFIX}}"
GIT_HTTP_INGRESS_HOST="${GIT_HTTP_INGRESS_HOST:-git.${K8S_TEST_DOMAIN_SUFFIX}}"
BUILD_GIT_HTTP_IMAGE="${BUILD_GIT_HTTP_IMAGE:-true}"
GIT_HTTP_IMAGE_REPO="${GIT_HTTP_IMAGE_REPO:-git-http-server}"
GIT_HTTP_IMAGE_TAG="${GIT_HTTP_IMAGE_TAG:-local}"

apply_hermes_gateway_secret() {
    local discord_token="$1"
    local openai_key="$2"
    local api_server_key="$3"
    local discord_allowed_users="${4:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}"
    local github_token="${5:-${GITHUB_TOKEN:-REPLACE_WITH_GITHUB_TOKEN}}"
    local linear_api_key="${6:-${LINEAR_API_KEY:-REPLACE_WITH_LINEAR_API_KEY}}"
    local naver_client_id="${7:-${NAVER_CLIENT_ID:-REPLACE_WITH_NAVER_CLIENT_ID}}"
    local naver_client_secret="${8:-${NAVER_CLIENT_SECRET:-REPLACE_WITH_NAVER_CLIENT_SECRET}}"
    local hf_token="${9:-${HF_TOKEN:-REPLACE_WITH_HF_TOKEN}}"

    kubectl create secret generic "${HERMES_SECRET_NAME}" \
        --namespace "${HERMES_NAMESPACE}" \
        --from-literal=DISCORD_BOT_TOKEN="${discord_token}" \
        --from-literal=OPENAI_API_KEY="${openai_key}" \
        --from-literal=HERMES_API_SERVER_KEY="${api_server_key}" \
        --from-literal=DISCORD_ALLOWED_USERS="${discord_allowed_users}" \
        --from-literal=GITHUB_TOKEN="${github_token}" \
        --from-literal=LINEAR_API_KEY="${linear_api_key}" \
        --from-literal=NAVER_CLIENT_ID="${naver_client_id}" \
        --from-literal=NAVER_CLIENT_SECRET="${naver_client_secret}" \
        --from-literal=HF_TOKEN="${hf_token}" \
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

log_ingress_routes() {
    log_info "External access (*.${K8S_TEST_DOMAIN_SUFFIX} — HTTPS on :443); add to /etc/hosts:"
    log_info "  <NODE_IP>  opik.${K8S_TEST_DOMAIN_SUFFIX} hermes.${K8S_TEST_DOMAIN_SUFFIX} hermes-api.${K8S_TEST_DOMAIN_SUFFIX} sglang.${K8S_TEST_DOMAIN_SUFFIX} embeddings.${K8S_TEST_DOMAIN_SUFFIX} leantime.${K8S_TEST_DOMAIN_SUFFIX} nebula-studio.${K8S_TEST_DOMAIN_SUFFIX} git.${K8S_TEST_DOMAIN_SUFFIX}"
    log_info "  Opik UI:           https://opik.${K8S_TEST_DOMAIN_SUFFIX}/"
    log_info "  Leantime PM:       https://leantime.${K8S_TEST_DOMAIN_SUFFIX}/  (community MCP: scripts/fixtures/leantime-mcp-cursor.json)"
    log_info "  Hermes dashboard:  https://hermes.${K8S_TEST_DOMAIN_SUFFIX}/"
    log_info "  Hermes API:        https://hermes-api.${K8S_TEST_DOMAIN_SUFFIX}/"
    log_info "  SGLang OpenAI:     https://sglang.${K8S_TEST_DOMAIN_SUFFIX}/v1/"
    log_info "  BGE-M3 TEI:        https://embeddings.${K8S_TEST_DOMAIN_SUFFIX}/v1/embeddings"
    log_info "  NebulaGraph Studio: https://nebula-studio.${K8S_TEST_DOMAIN_SUFFIX}/ (path-graph)"
    log_info "  Git HTTPS:         https://git.${K8S_TEST_DOMAIN_SUFFIX}/git/<repo>.git"
    log_info "  PostgreSQL (TCP):  psql -h <NODE_IP> -p ${POSTGRES_TCP_NODEPORT} -U hermes -d hermesdb"
}

ensure_leantime_chart() {
    local chart_dir="${ROOT_DIR}/helm/charts/leantime"
    local sync_script="${ROOT_DIR}/scripts/sync-leantime-chart.sh"
    if [ ! -f "${chart_dir}/Chart.yaml" ] || ! grep -q 'LEAN_APP_URL' "${chart_dir}/templates/deployment.yaml" 2>/dev/null; then
        if [ ! -x "${sync_script}" ]; then
            log_error "Leantime chart missing and sync script not found: ${sync_script}"
            exit 1
        fi
        log_info "Syncing Leantime Helm chart from upstream..."
        "${sync_script}"
    fi
    helm dependency build "${chart_dir}"
}

ensure_leantime_smtp_secret() {
    local sync_script="${ROOT_DIR}/scripts/sync-leantime-smtp-secret.sh"
    if [ ! -x "${sync_script}" ]; then
        log_error "Leantime SMTP sync script not found: ${sync_script}"
        exit 1
    fi
    "${sync_script}"
}

deploy_leantime() {
    local chart_dir="${ROOT_DIR}/helm/charts/leantime"
    local values_file="${ROOT_DIR}/helm/values/leantime.yaml"
    local app_url="https://${LEANTIME_INGRESS_HOST}"

    if ! kubectl get ingressclass nginx &>/dev/null; then
        log_error "IngressClass 'nginx' not found. Run deploy_ingress_nginx first."
        exit 1
    fi

    ensure_leantime_chart
    ensure_leantime_smtp_secret

    log_info "Installing/upgrading Leantime (${LEANTIME_VERSION}) in namespace '${LEANTIME_NAMESPACE}'..."
    helm upgrade --install "${LEANTIME_RELEASE}" "${chart_dir}" \
        --namespace "${LEANTIME_NAMESPACE}" \
        --create-namespace \
        -f "${values_file}" \
        --set "image.tag=${LEANTIME_VERSION}" \
        --set-string "app.url=${app_url}" \
        --wait \
        --timeout 20m

    log_info "Leantime UI: ${app_url}/  (first boot: ${app_url}/install)"
    log_info "Community MCP (Cursor): scripts/fixtures/leantime-mcp-cursor.json + uvx (see README → Leantime)"
}

deploy_opik() {
  log_info "Ensuring Opik Helm repo is registered..."
  helm repo add opik https://comet-ml.github.io/opik/ 2>/dev/null || true
  helm repo update opik

  log_info "Installing/upgrading Opik (${OPIK_VERSION}) in namespace '${OPIK_NAMESPACE}'..."
  helm upgrade --install "${OPIK_RELEASE}" opik/opik \
    --namespace "${OPIK_NAMESPACE}" \
    --create-namespace \
    -f "${ROOT_DIR}/helm/values/opik.yaml" \
    --set "component.backend.image.tag=${OPIK_VERSION}" \
    --set "component.python-backend.image.tag=${OPIK_VERSION}" \
    --set "component.python-backend.env.PYTHON_CODE_EXECUTOR_IMAGE_TAG=${OPIK_VERSION}" \
    --set "component.frontend.image.tag=${OPIK_VERSION}" \
    --wait \
    --timeout 20m
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

sync_hermes_pg_registry() {
    local sync_script="${ROOT_DIR}/scripts/sync-hermes-pg-registry.sh"
    if [ ! -x "${sync_script}" ]; then
        log_warn "Hermes PG registry sync script not found; skipping."
        return 0
    fi
    if ! kubectl get namespace ai-agents &>/dev/null; then
        log_warn "Namespace ai-agents missing; skipping Hermes PG registry sync."
        return 0
    fi
    log_info "Syncing Hermes PostgreSQL registry (all in-cluster :5432 services)..."
    "${sync_script}"
}

sync_k8s_test_tls_secret() {
    if [[ "${SKIP_K8S_TEST_TLS:-false}" == true ]]; then
        log_warn "SKIP_K8S_TEST_TLS=true — ingress-nginx HTTPS will fail without secret k8s-test-tls."
        return 0
    fi
    local sync_script="${ROOT_DIR}/scripts/sync-k8s-test-tls-secret.sh"
    if [ ! -x "${sync_script}" ]; then
        log_error "TLS sync script not found: ${sync_script}"
        exit 1
    fi
    log_info "Syncing mkcert wildcard TLS secret for *.${K8S_TEST_DOMAIN_SUFFIX}..."
    "${sync_script}"
}

deploy_ingress_nginx() {
    log_info "Ensuring ingress-nginx Helm repo is registered..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx

    # hostPort: clear Pending pods from a failed RollingUpdate (ports held by the old pod).
    if kubectl get deployment ingress-nginx-controller -n "${INGRESS_NAMESPACE}" &>/dev/null; then
        kubectl delete pods -n "${INGRESS_NAMESPACE}" \
            -l app.kubernetes.io/component=controller \
            --field-selector=status.phase=Pending \
            --ignore-not-found=true || true
    fi

    log_info "Installing/upgrading ${INGRESS_RELEASE} (hostPort + app ports) in namespace '${INGRESS_NAMESPACE}'..."
    helm upgrade --install "${INGRESS_RELEASE}" ingress-nginx/ingress-nginx \
        --namespace "${INGRESS_NAMESPACE}" \
        --create-namespace \
        -f "${ROOT_DIR}/helm/values/ingress-nginx.yaml" \
        --wait \
        --timeout 15m

    log_info "Waiting for ingress-nginx controller pods..."
    kubectl wait --namespace "${INGRESS_NAMESPACE}" \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s

    log_info "External HTTPS: https://<app>.${K8S_TEST_DOMAIN_SUFFIX}/ (port ${INGRESS_HTTPS_NODEPORT}); HTTP redirects to HTTPS"
    log_info "PostgreSQL TCP: <NODE_IP>:${POSTGRES_TCP_NODEPORT}"
}

ensure_git_http_auth_secret() {
    local user="${GIT_HTTP_USER:-git}"
    local pass="${GIT_HTTP_PASSWORD:-gitpassword}"

    if ! command -v openssl &> /dev/null; then
        log_error "openssl is required to create ${GIT_HTTP_AUTH_SECRET}."
        exit 1
    fi

    local hash
    hash="$(openssl passwd -apr1 "${pass}")"

    log_info "Applying Git HTTP basic-auth secret (${GIT_HTTP_AUTH_SECRET}) in ${GIT_HTTP_NAMESPACE}..."
    kubectl create secret generic "${GIT_HTTP_AUTH_SECRET}" \
        --namespace "${GIT_HTTP_NAMESPACE}" \
        --from-literal=htpasswd="${user}:${hash}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

deploy_git_http_server() {
    local chart_dir="${ROOT_DIR}/helm/charts/git-http-server"
    local values_file="${ROOT_DIR}/helm/values/git-http-server.yaml"

    if ! kubectl get namespace "${GIT_HTTP_NAMESPACE}" &> /dev/null; then
        log_warn "Namespace ${GIT_HTTP_NAMESPACE} not found; apply manifests/infra/git-namespace.yaml first."
    fi

    if ! kubectl get ingressclass nginx &> /dev/null; then
        log_error "IngressClass 'nginx' not found. Run deploy_ingress_nginx first."
        exit 1
    fi

    ensure_git_http_auth_secret

    if [[ "${BUILD_GIT_HTTP_IMAGE}" == true ]]; then
        if command -v docker &> /dev/null; then
            log_info "Building ${GIT_HTTP_IMAGE_REPO}:${GIT_HTTP_IMAGE_TAG} image..."
            docker build --platform "${GIT_HTTP_IMAGE_PLATFORM:-linux/amd64}" \
                -t "${GIT_HTTP_IMAGE_REPO}:${GIT_HTTP_IMAGE_TAG}" \
                "${ROOT_DIR}/docker/git-http-server"
        else
            log_warn "docker not found; ensure image ${GIT_HTTP_IMAGE_REPO}:${GIT_HTTP_IMAGE_TAG} exists on cluster nodes."
        fi
    fi

    log_info "Installing/upgrading ${GIT_HTTP_RELEASE} in namespace '${GIT_HTTP_NAMESPACE}' (requires ingress-nginx)..."
    helm upgrade --install "${GIT_HTTP_RELEASE}" "${chart_dir}" \
        --namespace "${GIT_HTTP_NAMESPACE}" \
        -f "${values_file}" \
        --set "image.repository=${GIT_HTTP_IMAGE_REPO}" \
        --set "image.tag=${GIT_HTTP_IMAGE_TAG}" \
        --set "ingress.enabled=true" \
        --set "ingress.className=nginx" \
        --set-string "ingress.host=${GIT_HTTP_INGRESS_HOST}" \
        --wait \
        --timeout 10m

    log_info "Git HTTPS (Ingress): https://${GIT_HTTP_INGRESS_HOST}/git/<repo>.git"
    log_info "Git HTTP in-cluster: http://${GIT_HTTP_RELEASE}.${GIT_HTTP_NAMESPACE}.svc.cluster.local/git/<repo>.git"
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
    sync_k8s_test_tls_secret
    deploy_ingress_nginx

    log_info "Ensuring Bitnami Helm repo is registered..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update
    
    log_info "Installing/upgrading PostgreSQL release in namespace 'postgres'..."
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace postgres \
        --create-namespace \
        -f "${ROOT_DIR}/helm/values/postgresql.yaml"

    ensure_pgvector_extension

    deploy_git_http_server

    deploy_leantime

    deploy_opik
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
            "${DISCORD_ALLOWED_USERS:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}" \
            "${GITHUB_TOKEN:-REPLACE_WITH_GITHUB_TOKEN}" \
            "${LINEAR_API_KEY:-REPLACE_WITH_LINEAR_API_KEY}" \
            "${NAVER_CLIENT_ID:-REPLACE_WITH_NAVER_CLIENT_ID}" \
            "${NAVER_CLIENT_SECRET:-REPLACE_WITH_NAVER_CLIENT_SECRET}" \
            "${HF_TOKEN:-REPLACE_WITH_HF_TOKEN}"
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
            read -rsp "GitHub token (GITHUB_TOKEN) [leave empty for placeholder]: " github_token_input
            echo ""
            read -rsp "Linear API key (LINEAR_API_KEY) [leave empty for placeholder]: " linear_api_key_input
            echo ""
            read -rsp "Naver client ID (NAVER_CLIENT_ID) [leave empty for placeholder]: " naver_client_id_input
            echo ""
            read -rsp "Naver client secret (NAVER_CLIENT_SECRET) [leave empty for placeholder]: " naver_client_secret_input
            echo ""
            log_info "Creating ${HERMES_SECRET_NAME} with provided values..."
            apply_hermes_gateway_secret \
                "${discord_token_input}" \
                "${openai_key_input}" \
                "${api_server_key_input}" \
                "${discord_users_input:-${HERMES_DEFAULT_DISCORD_ALLOWED_USERS}}" \
                "${github_token_input:-REPLACE_WITH_GITHUB_TOKEN}" \
                "${linear_api_key_input:-REPLACE_WITH_LINEAR_API_KEY}" \
                "${naver_client_id_input:-REPLACE_WITH_NAVER_CLIENT_ID}" \
                "${naver_client_secret_input:-REPLACE_WITH_NAVER_CLIENT_SECRET}" \
                "${HF_TOKEN:-REPLACE_WITH_HF_TOKEN}"
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

if [ "$HAS_HELM" = true ]; then
    sync_hermes_pg_registry
    log_ingress_routes
fi

log_info "Deployment sequence completed successfully!"

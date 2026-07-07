#!/usr/bin/env bash
# Vendor Leantime upstream Helm chart (v3.9.7) with LEAN_APP_URL patch for ingress HTTPS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/charts/leantime"
LEANTIME_TAG="${LEANTIME_CHART_TAG:-v3.9.7}"
UPSTREAM_REPO="${LEANTIME_UPSTREAM_REPO:-https://github.com/Leantime/leantime.git}"
PATCHER="${SCRIPT_DIR}/lib/patch-leantime-chart.py"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

if [[ -f "${CHART_DIR}/Chart.yaml" ]] && [[ "${LEANTIME_FORCE_SYNC:-false}" != true ]]; then
  if grep -q 'LEAN_APP_URL' "${CHART_DIR}/templates/deployment.yaml" 2>/dev/null; then
    log "Leantime chart already present at ${CHART_DIR} (set LEANTIME_FORCE_SYNC=true to re-sync)"
    exit 0
  fi
  warn "Chart exists but missing LEAN_APP_URL patch; re-syncing..."
fi

[[ -f "${PATCHER}" ]] || { echo "Missing patch helper: ${PATCHER}" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

log "Cloning Leantime ${LEANTIME_TAG} (helm/ only)..."
git clone --depth 1 --branch "${LEANTIME_TAG}" "${UPSTREAM_REPO}" "${tmpdir}/src"

rm -rf "${CHART_DIR}"
mkdir -p "$(dirname "${CHART_DIR}")"
cp -R "${tmpdir}/src/helm/." "${CHART_DIR}/"

python3 "${PATCHER}" "${CHART_DIR}"

log "Building chart dependencies (MariaDB)..."
helm dependency build "${CHART_DIR}" >/dev/null

log "Leantime chart synced to ${CHART_DIR} (tag ${LEANTIME_TAG})"

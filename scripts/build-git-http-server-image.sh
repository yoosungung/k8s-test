#!/usr/bin/env bash
# Build git-http-server:local and make it available to k3s/containerd.
# If SSH and local Docker are unavailable, use the in-cluster Kaniko job documented in
# README.md → Recovery & troubleshooting → git-http-server image missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_REPO="${GIT_HTTP_IMAGE_REPO:-git-http-server}"
IMAGE_TAG="${GIT_HTTP_IMAGE_TAG:-local}"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
BUILD_DIR="${ROOT_DIR}/docker/git-http-server"
# k3s GPU node (didim-gpu) is amd64; Mac/Colima often builds arm64 by default.
GIT_HTTP_IMAGE_PLATFORM="${GIT_HTTP_IMAGE_PLATFORM:-linux/amd64}"

# Build on the k3s node (recommended when Mac Colima/Docker is off).
# Example: GIT_HTTP_BUILD_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh
GIT_HTTP_BUILD_NODE="${GIT_HTTP_BUILD_NODE:-}"
GIT_HTTP_BUILD_NODE_PATH="${GIT_HTTP_BUILD_NODE_PATH:-/tmp/git-http-server-build}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

hint_colima() {
  cat >&2 <<'EOF'
Local Docker is not running. Options:
  1) Start Colima:  colima start
     Then re-run:   ./scripts/build-git-http-server-image.sh
  2) Build on the k3s node (no Mac Docker):
     GIT_HTTP_BUILD_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh
EOF
}

docker_ready() {
  command -v docker &>/dev/null || return 1
  docker info &>/dev/null
}

build_local() {
  echo "Building ${IMAGE} for ${GIT_HTTP_IMAGE_PLATFORM} (local Docker)..."
  docker build --platform "${GIT_HTTP_IMAGE_PLATFORM}" -t "${IMAGE}" "${BUILD_DIR}"
}

import_via_ssh() {
  local remote="${1:?}"
  local tar_name="${IMAGE_REPO}-${IMAGE_TAG}.tar"
  local tar="/tmp/${tar_name}"
  echo "Saving ${IMAGE} to ${tar}..."
  docker save "${IMAGE}" -o "${tar}"
  echo "Copying to ${remote}:/tmp/${tar_name} ..."
  scp "${tar}" "${remote}:/tmp/${tar_name}"
  rm -f "${tar}"

  # Non-interactive ssh cannot prompt for sudo; use a TTY or finish on the node.
  if [[ "${GIT_HTTP_IMPORT_USE_TTY:-}" == "1" ]]; then
    ssh -t "${remote}" "sudo k3s ctr images rm docker.io/library/${IMAGE_REPO}:${IMAGE_TAG} 2>/dev/null || true; sudo k3s ctr images import /tmp/${tar_name} && rm -f /tmp/${tar_name} && sudo k3s ctr images ls | grep -F '${IMAGE_REPO}'"
  else
    cat <<EOF
Copied to ${remote}:/tmp/${tar_name}

Import on the node (SSH shell on didim-gpu — sudo works there):
  sudo k3s ctr images import /tmp/${tar_name}
  sudo k3s ctr images ls | grep git-http-server
  rm -f /tmp/${tar_name}

Then:
  kubectl rollout restart deploy/git-http-server -n git

Or re-run with a TTY: GIT_HTTP_IMPORT_USE_TTY=1 GIT_HTTP_IMPORT_NODE=${remote} $0
EOF
  fi
}

build_on_node() {
  local remote="${GIT_HTTP_BUILD_NODE}"
  echo "Building ${IMAGE} on ${remote}..."
  ssh "${remote}" "mkdir -p '${GIT_HTTP_BUILD_NODE_PATH}'"
  rsync -az --delete "${BUILD_DIR}/" "${remote}:${GIT_HTTP_BUILD_NODE_PATH}/"
  ssh "${remote}" bash -s <<EOF
set -euo pipefail
if command -v docker &>/dev/null && docker info &>/dev/null; then
  docker build -t '${IMAGE}' '${GIT_HTTP_BUILD_NODE_PATH}'
  # k3s/containerd resolves bare names as docker.io/library/<repo>:<tag>
  docker save '${IMAGE}' | sudo k3s ctr images import -
  sudo k3s ctr images ls | grep -F '${IMAGE_REPO}' || { echo 'import failed' >&2; exit 1; }
elif command -v nerdctl &>/dev/null; then
  nerdctl -n k8s.io build -t '${IMAGE}' '${GIT_HTTP_BUILD_NODE_PATH}'
else
  echo 'Need docker or nerdctl on the node.' >&2
  exit 1
fi
sudo k3s ctr images ls | grep -F '${IMAGE_REPO}' || true
EOF
  echo "Built and imported ${IMAGE} on ${remote}"
  echo "Restart git-http-server: kubectl rollout restart deploy/git-http-server -n git"
}

if [[ -n "${GIT_HTTP_BUILD_NODE}" ]]; then
  build_on_node
  exit 0
fi

if docker_ready; then
  build_local
  if [[ -n "${GIT_HTTP_IMPORT_NODE:-}" ]]; then
    import_via_ssh "${GIT_HTTP_IMPORT_NODE}"
  else
    echo "Built ${IMAGE} locally. Import on the k3s node:"
    echo "  docker save ${IMAGE} -o /tmp/git-http-server.tar"
    echo "  scp /tmp/git-http-server.tar ${GIT_HTTP_IMPORT_NODE:-didim-gpu@192.168.150.200}:/tmp/"
    echo "  ssh ${GIT_HTTP_IMPORT_NODE:-didim-gpu@192.168.150.200} 'sudo k3s ctr images import /tmp/git-http-server.tar'"
    echo "Or: GIT_HTTP_IMPORT_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh"
  fi
  echo "Restart: kubectl rollout restart deploy/git-http-server -n git"
  exit 0
fi

if command -v docker &>/dev/null && [[ ! -S "${DOCKER_HOST:-$HOME/.colima/default/docker.sock}" ]] \
  && [[ -S "$HOME/.colima/default/docker.sock" || -d "$HOME/.colima" ]]; then
  hint_colima
  die "Colima/Docker socket not available."
fi

hint_colima
die "Docker is not available."

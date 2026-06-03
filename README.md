# Kubernetes Test Infrastructure

This repository contains configuration files, Helm charts, raw YAML manifests, and utility scripts to build and manage a Kubernetes test environment.

---

## Repository Structure

```text
├── AGENTS.md            # Guidelines for AI coding agents
├── README.md             # This documentation file
├── helm/                 # Helm charts and value overrides
│   ├── charts/           # Custom Helm charts
│   └── values/           # Values overrides for third-party charts
├── manifests/            # Raw Kubernetes YAML manifests
│   ├── apps/             # Application deployments, services, ingress
│   └── infra/            # Core infrastructure configs (namespaces, GPU, nodes)
└── scripts/              # Setup, deploy, and teardown scripts
    ├── deploy.sh         # Installs/Applies the test environment
    └── teardown.sh       # Cleans up all deployed resources
```

---

## Quick Start

### Prerequisites

Before running scripts or applying manifests, ensure you have:

1. `kubectl` installed and configured to point to your test Kubernetes cluster.
2. `helm` (v3+) installed.
3. Network access to the Kubernetes cluster.

**k3s:** The bundled **Traefik** Service LB (`svclb-traefik-*`) reserves **hostPort 80 and 443**. That blocks ingress-nginx from binding the same ports even when `ss -tlnp | grep ':80\|:443'` on the node shows nothing. Disable Traefik once on the server, then restart k3s:

```yaml
# /etc/rancher/k3s/config.yaml
disable:
  - traefik
```

```bash
sudo systemctl restart k3s   # or k3s-agent on agents
kubectl get pods -n kube-system | grep traefik   # should be gone
```

Then re-run `./scripts/deploy.sh` or upgrade ingress-nginx.

### Deploy the Test Environment

To deploy all configurations, infrastructure elements, and applications in the correct order:

```bash
./scripts/deploy.sh
```

For Hermes agents, you can provide secrets via environment variables (non-interactive):

```bash
export DISCORD_BOT_TOKEN='your-discord-bot-token'
export OPENAI_API_KEY='your-openai-api-key'
export HERMES_API_SERVER_KEY="$(openssl rand -hex 32)"   # optional: auto-generated if omitted in prompts
# optional:
# export DISCORD_ALLOWED_USERS='your-discord-username'

./scripts/deploy.sh
```

### Clean Up / Teardown

To remove all components and clean up the namespaces created for testing:

```bash
./scripts/teardown.sh
```

---

## External access (shared Ingress)

Apps use **ClusterIP** Services and reach the LAN via the shared [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) controller. Host-based routing uses **`*.k8s-test`**; the URL **port matches each app’s Service port** (e.g. Opik **5173**, SGLang **30000**, Git **80**). The controller binds those ports on the node with **hostPort** (and a small socat sidecar for extra HTTP/TCP aliases), so you do not use a shared **30080** hop.

Replace `<NODE_IP>` with any cluster node (e.g. `192.168.150.200`). HTTP apps use **`http://<name>.k8s-test:<app-port>/`** (no shared `30080` hop).

Add to `/etc/hosts`:

```text
<NODE_IP>  opik.k8s-test hermes.k8s-test hermes-api.k8s-test sglang.k8s-test git.k8s-test
```

| Service | Host | External URL | In-cluster |
| -------- | ------ | ------------ | ---------- |
| Ingress (HTTP/HTTPS) | — | `http://<NODE_IP>:80` / `https://<NODE_IP>:443` | — |
| PostgreSQL | — | `psql -h <NODE_IP> -p 5432 …` | `postgresql.postgres.svc.cluster.local:5432` |
| Opik UI | `opik.k8s-test` | `http://opik.k8s-test:5173/` | `opik-frontend.opik.svc.cluster.local:5173` |
| Hermes dashboard | `hermes.k8s-test` | `http://hermes.k8s-test:9119/` | `hermes-master.ai-agents.svc.cluster.local:9119` |
| Hermes API | `hermes-api.k8s-test` | `http://hermes-api.k8s-test:8642/` | `hermes-master.ai-agents.svc.cluster.local:8642` |
| SGLang OpenAI | `sglang.k8s-test` | `http://sglang.k8s-test:30000/v1/` | `sglang-gemma4-31b.llm-serving.svc.cluster.local:30000` |
| Git HTTP | `git.k8s-test` | `http://git.k8s-test:80/git/<repo>.git` | `git-http-server.git.svc.cluster.local/git/…` |

Ingress definitions: `[manifests/apps/ingress-routes.yaml](manifests/apps/ingress-routes.yaml)` (Git: `[helm/charts/git-http-server](helm/charts/git-http-server)`). Controller values: `[helm/values/ingress-nginx.yaml](helm/values/ingress-nginx.yaml)`.

```bash
kubectl get ingress -A
kubectl get pods -n ingress-nginx -o wide
```

The controller uses **hostPort** (not per-app NodePorts). If an upgrade stays `Pending` with `didn't have free ports`, delete stuck controller pods and re-run `./scripts/deploy.sh`, or:

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx -f helm/values/ingress-nginx.yaml --wait --timeout 15m
```

### Opik (agent tracing / experiments)

[Opik](https://github.com/comet-ml/opik) is installed via Helm when you run `./scripts/deploy.sh`. Self-hosted Opik has **no built-in authentication**—use only on trusted test networks.

Trace from your machine:

```bash
export OPIK_URL_OVERRIDE="http://opik.k8s-test:5173/api"
export OPIK_WORKSPACE="default"
pip install opik
opik configure --use_local
```

From pods inside the cluster:

```bash
export OPIK_URL_OVERRIDE="http://opik-frontend.opik.svc.cluster.local:5173/api"
```

Override the chart image tag with `OPIK_VERSION` (default `latest`), e.g. `OPIK_VERSION=2.0.18 ./scripts/deploy.sh`.

### Git HTTP server

Smart HTTP Git is served by the `git-http-server` Helm chart in namespace `git`. Repositories are **bare** repos on the PVC mounted at **`/srv/git`** inside the pod.

| Item | Value |
| -------- | ------ |
| Host | `git.k8s-test` (override: `GIT_HTTP_INGRESS_HOST`) |
| URL path | `/git/<repo>.git` |
| On-disk path | `/srv/git/<repo>.git` |
| Auth (test default) | user `git`, password `gitpassword` |

Add to `/etc/hosts` (same line as other `*.k8s-test` apps):

```text
<NODE_IP>  git.k8s-test
```

#### Create a repository

Replace `myrepo` with your repository name (use the `.git` suffix on disk).

**Inside the cluster** (recommended):

```bash
kubectl exec -n git deploy/git-http-server -- \
  sh -c 'mkdir -p /srv/git/myrepo.git && git init --bare /srv/git/myrepo.git && chown -R nginx:nginx /srv/git/myrepo.git'
```

**On the GPU node** (if you have shell access and the PVC is mounted on the node — usually not needed):

```bash
# Only if you know the volume path on the host; prefer kubectl exec above.
sudo mkdir -p /var/lib/rancher/k3s/storage/.../srv/git/myrepo.git
sudo git init --bare /path/to/myrepo.git
```

#### Clone, push, and pull

Clone URL pattern:

```text
http://git.k8s-test:80/git/<repo>.git
```

Examples:

```bash
# Clone (test credentials in URL)
git clone http://git:gitpassword@git.k8s-test:80/git/myrepo.git

# Or store credentials once
git clone http://git.k8s-test:80/git/myrepo.git
# Username: git   Password: gitpassword

cd myrepo
git remote -v
# push a branch (after you have commits)
git push origin main
```

From another pod in the cluster:

```bash
git clone http://git:gitpassword@git-http-server.git.svc.cluster.local/git/myrepo.git
```

#### Sample repository (`sample.git`)

```bash
kubectl exec -n git deploy/git-http-server -- \
  sh -c 'mkdir -p /srv/git/sample.git && git init --bare /srv/git/sample.git && chown -R nginx:nginx /srv/git/sample.git'

git clone http://git:gitpassword@git.k8s-test:80/git/sample.git
```

Override credentials when deploying: `GIT_HTTP_USER`, `GIT_HTTP_PASSWORD` in `scripts/deploy.sh`.

#### Build the image (first-time / after Dockerfile changes)

Chart uses `git-http-server:local` with `pullPolicy: Never` — build on the node or Mac, then import into k3s:

```bash
# Mac: start Docker first (builds linux/amd64 for the GPU node by default)
colima start
./scripts/build-git-http-server-image.sh

# Or build on the k3s node (no local Docker)
GIT_HTTP_BUILD_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh
kubectl rollout restart deploy/git-http-server -n git
```

After `GIT_HTTP_IMPORT_NODE=...`, the tarball is copied to the node; **run import on the node** (Mac `ssh sudo` often fails without a TTY):

```bash
sudo k3s ctr images import /tmp/git-http-server-local.tar
sudo k3s ctr images ls | grep git-http-server
kubectl rollout restart deploy/git-http-server -n git
```

Or from Mac with password prompt: `GIT_HTTP_IMPORT_USE_TTY=1 GIT_HTTP_IMPORT_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh`

If import shows `linux/arm64` or `no match for platform`, the image was built for the wrong CPU. Rebuild for amd64:

```bash
GIT_HTTP_IMAGE_PLATFORM=linux/amd64 ./scripts/build-git-http-server-image.sh
GIT_HTTP_IMPORT_USE_TTY=1 GIT_HTTP_IMPORT_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh
```

On the node, remove a bad arch before re-import: `sudo k3s ctr images rm docker.io/library/git-http-server:local`
```

### PostgreSQL credentials (test defaults)

Defined in `[helm/values/postgresql.yaml](helm/values/postgresql.yaml)`:


| User       | Database   | Password         |
| ---------- | ---------- | ---------------- |
| `hermes`   | `hermesdb` | `hermespassword` |
| `postgres` | *(admin)*  | `adminpassword`  |


The `hermesdb` database is initialized with the **pgvector** extension.

```bash
psql -h <NODE_IP> -p 5432 -U hermes -d hermesdb
```

### SGLang context / KV pool

Gemma 4 31B on 2×4090: **`--context-length 16384` alone is not enough**. SGLang sizes the KV pool from free VRAM after weights. With **`dp-size=2`**, each GPU loads a full copy of the model, so startup logs often show `max_total_num_tokens≈3800` and requests log `Truncated` / `max_req_input_len=3826` even though `context_len=16384`.

Recommended layout (see [SGLang hyperparameter tuning](https://sgl-project.github.io/advanced_features/hyperparameter_tuning.html)):

| Setting | Why |
|--------|-----|
| **`tp-size=2`, `dp-size=1`** | Shard weights across both GPUs; one larger KV pool instead of two small ones. |
| **`--disable-cuda-graph`** | Reserves 5–8 GB `available_gpu_mem` for activations/KV tuning headroom. |
| **`/dev/shm` emptyDir (16Gi)** | Default pod shm (~64Mi) causes `NCCL error` when `tp>1` ([SGLang #3666](https://github.com/sgl-project/sglang/issues/3666)). |
| **`NCCL_P2P_DISABLE=1`** | Workaround for P2P/ACS issues on some 2-GPU hosts. |
| No **`--allow-auto-truncate`** | Avoid silent truncation ([SGLang #21136](https://github.com/sgl-project/sglang/issues/21136)). |
| **`--tool-call-parser gemma4`** + **`--reasoning-parser gemma4`** | LangChain/deepagents need `message.tool_calls`, not raw `<\|tool_call>call:...` text in `content` ([Gemma 4 cookbook](https://docs.sglang.io/cookbook/autoregressive/Google/Gemma4)). Auto-detect in logs is not enough; the CLI flags must be set. |

After deploy, confirm: `max_total_num_tokens` ≫ 8192, no `Truncated` in logs, and `./scripts/verify-sglang.sh` passes the tool-call probe.

```bash
kubectl apply -f manifests/apps/sglang-gemma4-31b.yaml
chmod +x scripts/verify-sglang.sh
./scripts/verify-sglang.sh
```

---

## Directory Reference

### 1. [Helm (`/helm`)](file:///Users/suyoo/Documents/works/test_infra/helm/)

- **Custom Charts**: Put charts that you build internally inside `helm/charts/`.
- **Values Overrides**: Place values files for public charts inside `helm/values/` (e.g. `ingress-nginx.yaml`).

### 2. [Manifests (`/manifests`)](file:///Users/suyoo/Documents/works/test_infra/manifests/)

- **Infrastructure (`/manifests/infra`)**: Custom resources like namespaces, node configuration/affinity setup, GPU configuration, or storage classes.
- **Applications (`/manifests/apps`)**: Standard YAMLs for deploying target testing apps (Deployments, Services, Ingresses).

### 3. [Scripts (`/scripts`)](file:///Users/suyoo/Documents/works/test_infra/scripts/)

- Contains helper and driver scripts. Always run from the root directory or ensure path-resolving logic within the scripts.


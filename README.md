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

### Local HTTPS (`*.k8s-test` on port 443)

HTTP apps are exposed as **`https://<app>.k8s-test/`** (port **443**) via ingress-nginx and a mkcert wildcard certificate. In-cluster service URLs stay `http://` on their ClusterIP ports.

**One-time on your Mac** (trust + issue cert):

```bash
brew install mkcert nss
mkcert -install
mkdir -p .certs
cd .certs && mkcert "*.k8s-test"
```

**Before deploy** (upload cert to the cluster):

```bash
./scripts/sync-k8s-test-tls-secret.sh
./scripts/deploy.sh --force
```

Or let `deploy.sh` call the sync script automatically. Override paths with `K8S_TEST_TLS_CERT` / `K8S_TEST_TLS_KEY`, or cert directory with `K8S_TEST_TLS_DIR` (default: `.certs/`). Skip TLS upload only for dry runs: `SKIP_K8S_TEST_TLS=true ./scripts/deploy.sh --force`.

Validate config (no cluster required):

```bash
./scripts/test-k8s-test-tls-config.sh
```

**Third-party AV (e.g. Kaspersky):** if HTTPS still warns after `mkcert -install`, add `*.k8s-test` to SSL scanning exceptions.

### Hermes operator RBAC

`manifests/infra/hermes-k8s-operator-rbac.yaml` grants the in-cluster Hermes service account (`ai-agents/hermes-master-sa`) broad Kubernetes operator permissions for monitoring and day-to-day remediation.

**Monitoring (always on):** wildcard `get/list/watch` on `apiGroups: ["*"]` / `resources: ["*"]` plus explicit subresources (`pods/log`, `nodes/proxy|stats|metrics`) and API-discovery `nonResourceURLs`. New Helm charts and CRDs (NebulaGraph, Opik/ClickHouse, Argo, k3s `helmcharts`, …) are readable without editing this file.

**Remediation (explicit):** PV/PVC patch/update/delete, workload scale/restart/patch, Service/Ingress fixes, pod eviction/deletion, exec/port-forward, node cordon/uncordon, NebulaGraph CR patches, and Opik ClickHouse CR patches. RBAC **write** is intentionally denied so Hermes cannot escalate privileges.

Validate before deploy:

```bash
./scripts/test-hermes-k8s-operator-rbac.sh
kubectl apply -f manifests/infra/hermes-k8s-operator-rbac.yaml
```

**Further permissions to consider (not yet granted):**

| Area | Gap | Suggested approach |
| ------ | ----- | ------------------- |
| Argo Workflows | `workflows.argoproj.io` read-only today | Add `patch/update/delete` only if Hermes must cancel/retry CI workflows |
| k3s Helm CRs | `helmcharts.helm.cattle.io` read-only | Prefer `helm upgrade` via Job + cluster-admin SA; avoid giving Hermes k3s addon write |
| Admission webhooks | read via wildcard | Do **not** grant write on `validatingwebhookconfigurations` / `mutatingwebhookconfigurations` |
| GPU metrics | DCGM on `:9400` | No extra RBAC; use `kubectl port-forward` or in-cluster Prometheus scrape |
| Namespace lifecycle | no `namespaces` write | Grant `patch` on `namespaces` only if Hermes must label/annotate namespaces |
| Self-check | no `subjectaccessreviews` create | Optional: allow `create` on `subjectaccessreviews` so Hermes can verify its own `can-i` before remediation |

Alternative for mutating permissions: split into two bindings — `hermes-k8s-monitor` (wildcard read) + `hermes-k8s-remediator` (explicit writes) — and enable the second only during incidents.

### GPU telemetry (DCGM exporter)

`manifests/infra/dcgm-exporter.yaml` provides NVIDIA DCGM metrics on port `9400` in the `gpu-operator` namespace. It is applied automatically by `./scripts/deploy.sh` because it lives under `manifests/infra/`; apply it directly with cluster-admin credentials if you only want GPU telemetry:

```bash
kubectl apply -f manifests/infra/gpu-operator-namespace.yaml
kubectl apply -f manifests/infra/dcgm-exporter.yaml
kubectl rollout status daemonset/dcgm-exporter -n gpu-operator --timeout=180s
kubectl -n gpu-operator port-forward svc/dcgm-exporter 9400:9400
curl -s localhost:9400/metrics | grep -E 'DCGM_FI_DEV_GPU_UTIL|DCGM_FI_DEV_FB_USED' | head
```

The exporter is intentionally separate from workload GPU requests so it does not reserve a GPU through the scheduler.

### Deploy the Test Environment

To deploy all configurations, infrastructure elements, and applications in the correct order:

```bash
./scripts/deploy.sh
```

`deploy.sh` applies resources in dependency order:

1. **Namespaces & infra** — `manifests/infra/` (postgres, git, ingress-nginx, …)
2. **Helm releases** — ingress-nginx → PostgreSQL (+ pgvector) → git-http-server → **Leantime** → Opik
3. **Secrets** — Hugging Face, Hermes gateway/auth
4. **Apps** — `manifests/apps/` (Hermes, SGLang, **BGE-M3 TEI**, ingress routes)

**Qdrant · NebulaGraph** — owned by [path-graph](../path-graph). Deploy separately:

```bash
cd ../path-graph && make deploy-qdrant-nebula
```

See [path-graph deploy/SETUP.md](../path-graph/deploy/SETUP.md#qdrant--nebulagraph).

BGE-M3 TEI-only apply (after `llm-serving` namespace and `hf-token-secret` exist):

```bash
./scripts/test-bge-m3-tei-config.sh
kubectl apply -f manifests/apps/bge-m3-tei.yaml
kubectl apply -f manifests/apps/ingress-routes.yaml   # embeddings.k8s-test route
./scripts/verify-bge-m3-tei.sh
```

See [BGE-M3 embeddings (CPU TEI)](#bge-m3-embeddings-cpu-tei) for RAG wiring and client examples.

Leantime-only apply (after ingress-nginx and TLS secret exist):

```bash
./scripts/test-leantime-config.sh
./scripts/sync-leantime-chart.sh    # first time or LEANTIME_FORCE_SYNC=true
kubectl apply -f manifests/infra/leantime-namespace.yaml
# deploy_leantime() in deploy.sh, or full: ./scripts/deploy.sh --force
kubectl apply -f manifests/apps/ingress-routes.yaml
./scripts/verify-leantime.sh
```

See [Leantime (project management + community MCP)](#leantime-project-management--community-mcp).

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

## Recovery & troubleshooting

Runbooks for common failures on the single-node k3s test cluster (`didim-gpu`). After fixing the root cause, workloads usually reconcile within **a few minutes**; image-related failures need extra steps below.

### Hermes gateway / API (`:8642`) stuck

**Symptoms**

- `https://hermes-api.k8s-test/` or in-pod `127.0.0.1:8642` connection refused
- Gateway log loops: `Gateway already running (PID …)`
- `gateway_state.json` shows `api_server.state: disconnected` while argv is `hermes gateway restart` (not `gateway run`)

**Cause:** A stuck `hermes gateway restart` process holds the gateway PID lock; s6 cannot start a healthy `gateway run`, so the API server never binds `:8642`. (`hermes-wiki-master` has no API server by design — only dashboard `:9119`.)

**Fix** ([`manifests/apps/hermes-master.yaml`](manifests/apps/hermes-master.yaml)):

```bash
kubectl exec -n ai-agents hermes-master-0 -- sh -c \
  'su -s /bin/sh hermes -c "HERMES_HOME=/opt/data /opt/hermes/.venv/bin/hermes gateway stop"'
# s6 restarts gateway; wait a few seconds, then verify:
kubectl exec -n ai-agents hermes-master-0 -- sh -c \
  'python3 -c "import json;d=json.load(open(\"/opt/data/gateway_state.json\"));print(d[\"argv\"], {k:v[\"state\"] for k,v in d[\"platforms\"].items()})"'
kubectl exec -n ai-agents hermes-master-0 -- sh -c \
  'curl -sS -m 5 -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:8642/v1/models'
```

Expect `argv` containing `gateway run`, `api_server: connected`, and HTTP 200 from `/v1/models`.

### Node disk pressure (`FailedScheduling` / untolerated taint)

**Symptoms**

```text
Warning  FailedScheduling  ...  0/1 nodes are available: 1 node(s) had untolerated taint(s).
```

```bash
kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'
# Taints: node.kubernetes.io/disk-pressure:NoSchedule
# DiskPressure: True
```

**Cause:** kubelet adds `node.kubernetes.io/disk-pressure:NoSchedule` when disk is low. Pods without that toleration stay `Pending`.

**Fix**

1. Free disk on the node (container images, logs, `/var/lib/rancher`, unused PVC data).
2. Wait until kubelet clears the condition (typically within 1–2 minutes):

```bash
kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'
# DiskPressure: False, Taints: <none>
```

3. Controllers (Deployment/StatefulSet) schedule new pods automatically. Init-heavy pods (Hermes, Opik backend) may take several more minutes.

**Do not** add tolerations for `disk-pressure` unless you intend to schedule onto a still-starved disk.

### BGE-M3 TEI startup slow / OOM / high CPU

**Symptoms**

```text
Startup probe failed: Get "http://...:80/health": connection refused
```

Pod stays `0/1` for several minutes on first deploy, or CPU spikes during bulk indexing.

**Cause:** First boot downloads ~1.1 GB model weights into the host `hf_cache` mount. CPU TEI can saturate all cores during large client batches.

**Fix**

```bash
kubectl logs -n llm-serving deploy/bge-m3-tei --tail=80
kubectl get pods -n llm-serving -l app=bge-m3-tei

# Wait for model load (startupProbe allows ~10 min)
kubectl rollout status deploy/bge-m3-tei -n llm-serving --timeout=600s
./scripts/verify-bge-m3-tei.sh
```

If clients time out on bulk embeds, lower per-request batch size (≤16 texts) or raise client timeout. Manifest already sets `--max-client-batch-size 16` and `TOKENIZATION_WORKERS=4`.

**External URL not reachable:** ensure `/etc/hosts` includes `embeddings.k8s-test`, mkcert is installed (`mkcert -install`), TLS secret exists (`./scripts/sync-k8s-test-tls-secret.sh`), and ingress-nginx binds `:443` ([`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml)). Re-upgrade if needed:

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx -f helm/values/ingress-nginx.yaml --wait --timeout 15m
```

### Stale pods after an incident

After disk pressure or node restarts, old pods may remain in `Error` or `ContainerStatusUnknown` while new healthy replicas already run.

```bash
# See what's unhealthy
kubectl get pods -A | awk 'NR==1 || $4!="Running" && $4!="Completed"'

# Delete leftovers in one namespace (example: opik)
kubectl delete pod -n opik \
  opik-backend-7bddb6568f-2czwv \
  --ignore-not-found
```

Prefer **per-namespace, per-pod** deletes. Avoid cluster-wide force-delete unless you know every affected workload.

### git-http-server image missing (`ErrImageNeverPull`)

Chart uses `git-http-server:local` with `imagePullPolicy: Never`. The image must exist in k3s containerd on the node. Disk cleanup often removes it.

**Option A — Mac or node with Docker** (see also [Build the image](#build-the-image-first-time--after-dockerfile-changes)):

```bash
./scripts/build-git-http-server-image.sh
# or: GIT_HTTP_BUILD_NODE=didim-gpu@<NODE_IP> ./scripts/build-git-http-server-image.sh
kubectl rollout restart deploy/git-http-server -n git
```

**Option B — In-cluster Kaniko** (no SSH, no local Docker; `kubectl` only):

```bash
# 1) ConfigMap with Dockerfile + nginx config (entrypoint is inlined in Dockerfile for Kaniko)
kubectl create configmap git-http-server-docker -n git \
  --from-file=Dockerfile=docker/git-http-server/Dockerfile \
  --from-file=nginx-default.conf=docker/git-http-server/nginx-default.conf \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Build on didim-gpu and import into k3s containerd
kubectl apply -f manifests/apps/git-http-server-image-build-job.yaml
kubectl wait -n git --for=condition=complete job/build-git-http-server-image --timeout=180s

# 3) Restart deployment
kubectl rollout restart deploy/git-http-server -n git
kubectl get pods -n git -l app.kubernetes.io/name=git-http-server

# 4) Optional cleanup
kubectl delete job -n git build-git-http-server-image --ignore-not-found
```

**Note:** `docker/git-http-server/Dockerfile` embeds the entrypoint via `printf` because Kaniko + ConfigMap context does not reliably `COPY` a separate `entrypoint.sh`. Keep `docker/git-http-server/entrypoint.sh` in sync when you change startup logic.

**Verify image on node** (requires a node debug pod or shell on the node):

```bash
kubectl debug node/didim-gpu --profile=sysadmin --image=busybox:1.36 -- sleep 300
# Pod lands in the current namespace; then:
kubectl exec -n <ns> node-debugger-didim-gpu-<suffix> -- \
  chroot /host k3s ctr images ls | grep git-http-server
```

### SGLang image pull failures (`ImagePullBackOff`)

Large image `lmsysorg/sglang:dev-cu12` (~10 GB). Concurrent pulls after disk recovery can hit registry QPS limits (`pull QPS exceeded`).

```bash
# Stop failing pull loops
kubectl scale deploy -n llm-serving sglang-gemma4-12b --replicas=0

# Pre-pull on the node (via node debug pod; replace namespace/pod name)
kubectl debug node/didim-gpu --profile=sysadmin --image=busybox:1.36 -- sleep 600
kubectl exec -n <ns> node-debugger-didim-gpu-<suffix> -- \
  chroot /host k3s ctr images pull docker.io/lmsysorg/sglang:dev-cu12

# Restore replicas
kubectl scale deploy -n llm-serving sglang-gemma4-12b --replicas=2
kubectl rollout status deploy -n llm-serving sglang-gemma4-12b --timeout=30m

# Verify
./scripts/verify-sglang.sh
```

Manifest uses `imagePullPolicy: IfNotPresent`, so a successful node pull is reused by new pods.

### Recovery checklist (quick)

| Workload | Ready check | If not healthy |
| -------- | ----------- | -------------- |
| Node | `DiskPressure: False`, no disk taint | Free disk on node |
| Hermes | `kubectl get sts -n ai-agents hermes-master` | Wait for init; check secrets |
| Opik | `kubectl get deploy -n opik` | Wait for init images; delete stale pods |
| ingress-nginx | `kubectl get deploy -n ingress-nginx` | Delete unknown pods; helm upgrade if ports stuck |
| postgresql | `kubectl get sts -n postgres` | Wait for PVC; check evicted pods |
| SGLang | `2/2` in `llm-serving` | Pre-pull image (above) |
| BGE-M3 TEI | `1/1` in `llm-serving` | `./scripts/verify-bge-m3-tei.sh`; first start downloads ~1.1 GB model |
| git-http-server | `1/1` in `git` | Rebuild/import image (above) |
| Leantime | `1/1` in `leantime` | `./scripts/verify-leantime.sh`; first boot → `/install` |
| Qdrant / NebulaGraph | path-graph repo | `cd ../path-graph && make verify-qdrant-nebula` |

---

## External access (shared Ingress)

Apps use **ClusterIP** Services and reach the LAN via the shared [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) controller. Host-based routing uses **`*.k8s-test`** on **HTTPS port 443** (mkcert wildcard TLS; see [Local HTTPS](#local-https-k8s-test-on-port-443)). HTTP on port 80 redirects to HTTPS.

Replace `<NODE_IP>` with any cluster node (e.g. `192.168.150.200`). External URLs use **`https://<name>.k8s-test/`** (port 443, omit in browser). In-cluster URLs remain `http://<svc>.<ns>.svc.cluster.local:<port>`.

Add to `/etc/hosts`:

```text
<NODE_IP>  opik.k8s-test hermes.k8s-test hermes-api.k8s-test sglang.k8s-test embeddings.k8s-test leantime.k8s-test qdrant.k8s-test nebula-studio.k8s-test git.k8s-test
```

| Service | Host | External URL | In-cluster |
| -------- | ------ | ------------ | ---------- |
| Ingress (HTTPS) | — | `https://<NODE_IP>:443` | — |
| PostgreSQL | — | `psql -h <NODE_IP> -p 5432 …` | `postgresql.postgres.svc.cluster.local:5432` |
| Qdrant REST / Web UI | `qdrant.k8s-test` | `https://qdrant.k8s-test/` | `qdrant.qdrant.svc.cluster.local:6333` (path-graph) |
| Qdrant gRPC | — | `<NODE_IP>:6334` | `qdrant.qdrant.svc.cluster.local:6334` (path-graph) |
| Opik UI | `opik.k8s-test` | `https://opik.k8s-test/` | `opik-frontend.opik.svc.cluster.local:5173` |
| Leantime PM | `leantime.k8s-test` | `https://leantime.k8s-test/` | `leantime.leantime.svc.cluster.local:80` |
| Hermes dashboard | `hermes.k8s-test` | `https://hermes.k8s-test/` | `hermes-master.ai-agents.svc.cluster.local:9119` |
| Hermes API | `hermes-api.k8s-test` | `https://hermes-api.k8s-test/` | `hermes-master.ai-agents.svc.cluster.local:8642` |
| SGLang OpenAI | `sglang.k8s-test` | `https://sglang.k8s-test/v1/` | `sglang-gemma4-12b.llm-serving.svc.cluster.local:30000` |
| BGE-M3 TEI | `embeddings.k8s-test` | `https://embeddings.k8s-test/v1/embeddings` | `bge-m3-tei.llm-serving.svc.cluster.local:8080` |
| Git HTTPS | `git.k8s-test` | `https://git.k8s-test/git/<repo>.git` | `git-http-server.git.svc.cluster.local/git/…` |
| NebulaGraph Studio | `nebula-studio.k8s-test` | `https://nebula-studio.k8s-test/` | `nebula-studio.nebula.svc.cluster.local:7001` (path-graph) |
| NebulaGraph graphd | — | `nebula-console -addr <NODE_IP> -port <NodePort> -u root -p nebula` | `nebula-graphd-svc.nebula.svc.cluster.local:9669` (path-graph) |

**Ingress routing:** HTTP apps use host `*.k8s-test` rules in [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml) (Qdrant/Studio routes in [path-graph](../path-graph/deploy/k8s/infra/manifests/ingress-routes.yaml)). TLS terminates on ingress-nginx **:443** using secret `ingress-nginx/k8s-test-tls` ([`scripts/sync-k8s-test-tls-secret.sh`](scripts/sync-k8s-test-tls-secret.sh)). Qdrant gRPC (`6334`) and PostgreSQL (`5432`) use **TCP stream** passthrough (not HTTPS).

Ingress definitions: [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml) (Git: [`helm/charts/git-http-server`](helm/charts/git-http-server)). Controller values: [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml).

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
export OPIK_URL_OVERRIDE="https://opik.k8s-test/api"
export OPIK_WORKSPACE="default"
pip install opik
opik configure --use_local
```

From pods inside the cluster:

```bash
export OPIK_URL_OVERRIDE="http://opik-frontend.opik.svc.cluster.local:5173/api"
```

Override the chart image tag with `OPIK_VERSION` (default `latest`), e.g. `OPIK_VERSION=2.0.18 ./scripts/deploy.sh`.

### Leantime (project management + community MCP)

[Leantime](https://github.com/Leantime/leantime) v3.9.7 is deployed via the vendored Helm chart in [`helm/charts/leantime`](helm/charts/leantime) (synced from upstream with `LEAN_APP_URL` patch: [`scripts/sync-leantime-chart.sh`](scripts/sync-leantime-chart.sh)). Values: [`helm/values/leantime.yaml`](helm/values/leantime.yaml). MariaDB runs as a subchart (separate from Hermes PostgreSQL).

Validate before deploy:

```bash
./scripts/test-leantime-config.sh
```

First visit: **`https://leantime.k8s-test/install`** — complete the setup wizard once. Override version: `LEANTIME_VERSION=3.9.7 ./scripts/deploy.sh --force`.

**SMTP (Gmail 등):** 비밀번호는 Helm values에 넣지 않습니다. Secret `leantime-smtp`에 저장합니다.

```bash
LEANTIME_SMTP_PASSWORD='your-gmail-app-password' ./scripts/sync-leantime-smtp-secret.sh
./scripts/deploy.sh --force   # deploy_leantime()가 Secret 동기화 포함
```

`deploy.sh`는 Secret이 이미 있으면 비밀번호 env 없이도 진행합니다. 비밀번호 변경 시 위 sync 스크립트를 다시 실행한 뒤 `kubectl rollout restart deploy/leantime -n leantime`.

**Free community MCP (no Marketplace plugin):** uses [daniel-eder/leantime-mcp](https://github.com/daniel-eder/leantime-mcp) against Leantime’s JSON-RPC API (no paid Marketplace plugin).

##### Cursor MCP 등록 (community)

1. **사전 조건**
   - Leantime 접속: `https://leantime.k8s-test` (`/etc/hosts`에 노드 IP 등록)
   - 로컬에 `uv` 설치: `brew install uv` (`uvx` 명령 제공)

2. **Leantime API Key 발급**
   - 로그인 → **Settings (회사 아이콘)** → **Company** → **API Keys** → Generate
   - 키 형식 예: `lt_username_…` (한 번만 표시되므로 복사해 둠)

3. **Cursor에 MCP 서버 추가**
   - Cursor → **Settings** → **MCP** → **Add new global MCP server** (또는 프로젝트 `.cursor/mcp.json`)
   - [`scripts/fixtures/leantime-mcp-cursor.json`](scripts/fixtures/leantime-mcp-cursor.json) 내용을 붙여넣고 값 교체:

```json
{
  "mcpServers": {
    "leantime": {
      "command": "uvx",
      "args": [
        "--from",
        "git+https://github.com/daniel-eder/leantime-mcp.git",
        "leantime-mcp"
      ],
      "env": {
        "LEANTIME_URL": "https://leantime.k8s-test",
        "LEANTIME_API_KEY": "lt_…",
        "LEANTIME_USER_EMAIL": "you@example.com"
      }
    }
  }
}
```

4. **Cursor 재시작** 후 채팅에서 예: “List my Leantime projects”

5. **“내 태스크” 조회**가 필요하면 API Key 대신 **Profile → Personal Access Tokens** (v3.9.2+ 코어) 사용 권장.

**검증 (터미널):**

```bash
LEANTIME_URL=https://leantime.k8s-test \
LEANTIME_API_KEY='lt_…' \
LEANTIME_USER_EMAIL='you@example.com' \
uvx --from git+https://github.com/daniel-eder/leantime-mcp.git leantime-mcp --help
```

For user-scoped queries (“my tasks”), prefer **Profile → Personal Access Tokens** (core since v3.9.2) over service API keys.

Post-deploy check:

```bash
./scripts/verify-leantime.sh
```

#### PHP-FPM tuning (k8s-test)

The official `leantime/leantime` image ships aggressive defaults (`memory_limit=1G`, `pm.max_children=50`), which caused **OOMKilled** under the install wizard on a 1–2Gi Pod limit. This repo overrides them via ConfigMap ([`helm/charts/leantime/templates/php-tuning-configmap.yaml`](helm/charts/leantime/templates/php-tuning-configmap.yaml)) mounted into the Pod:

| Setting | Image default | k8s-test override (`helm/values/leantime.yaml` → `php.tuning`) |
| -------- | ------------- | -------------------------------------------------------------- |
| `memory_limit` | 1G | **512M** |
| `pm.max_children` | 50 | **8** |
| Pod memory limit | — | **2Gi** (request 512Mi) |

Tune in [`helm/values/leantime.yaml`](helm/values/leantime.yaml):

```yaml
php:
  tuning:
    enabled: true
    memoryLimit: 512M
    pmMaxChildren: 8
resources:
  limits:
    memory: 2Gi
```

Verify effective PHP limit after deploy: `kubectl exec -n leantime deploy/leantime -- php -r 'echo ini_get("memory_limit");'`

#### `/files/browse` 502 / memory exhausted (k8s-test patch)

**Symptoms:** `https://leantime.k8s-test/files/browse` returns **502** (nginx) or **500**; PHP log shows `Allowed memory size exhausted` in compiled views under `storage/framework/views/` (often `projectSelector` / `headMenu`). Kanban and other pages may still work.

**Root cause (Leantime 3.9.7):** Laravel `@include` merges `get_defined_vars()` into child views. On `/files/browse`, two bugs combine:

1. **`browse.blade.php`** sets `$module` / `$action` in `@section('content')`, which leak into `global::layouts.app`. The layout’s `@isset($action, $module) @include("$module::$action")` then **re-includes the browse template recursively** (not `@yield`).
2. **Menu `projectSelector` partials** nest `@include('menu::partials.*')`, multiplying parent scope (project lists, page vars) on each level.

**k8s-test fix:** ConfigMap blade patches mounted by Helm when `app.patch.filesBrowseFix.enabled: true` ([`helm/values/leantime.yaml`](helm/values/leantime.yaml)). Patches live under [`helm/charts/leantime/patches/`](helm/charts/leantime/patches/); gate: [`scripts/test-leantime-files-browse-fix.sh`](scripts/test-leantime-files-browse-fix.sh).

| Patch | Change |
| ----- | ------ |
| `Files/Templates/browse.blade.php` | Remove unused `$module` / `$action` (stops layout recursion) |
| `Menu/Templates/partials/*.blade.php` | Replace nested `@include` with isolated `view(...)->render()` |
| `Menu/Templates/projectSelector.blade.php`, `headMenu.blade.php` | Same for wrapper / loginInfo / stopwatch |
| `Views/Templates/layouts/app.blade.php` | `view('menu::headMenu')` / `view('menu::menu')` instead of `@include` |
| `Files/Templates/showAll.blade.php` | Fix broken `@if` inside form `action` |

**Diagnose:**

```bash
./scripts/diagnose-leantime-files-browse.sh
kubectl exec -n leantime deploy/leantime -- grep -E 'memory|ERROR' /var/www/html/storage/logs/leantime-$(date +%F).log | tail -5
```

**After patch ConfigMap changes:** subPath mounts do not hot-reload — Helm annotates `checksum/app-patch` to roll Pods; postStart clears `storage/framework/views/*.php`.

**Verify:**

```bash
./scripts/test-leantime-files-browse-fix.sh
# logged-in pod curl (or browser): /files/browse → 200
```

Upstream tracking: [Leantime/leantime#3612](https://github.com/Leantime/leantime/issues/3612).

#### 프로젝트 삭제가 안 될 때

Leantime은 프로젝트에 **남은 to-do(티켓)** 가 있으면 삭제를 막습니다. 메시지 예: *“Can't delete project. There are still to-dos in this project.”* — 마일스톤·서브태스크도 `zp_tickets`에 포함됩니다 ([GitHub #251](https://github.com/Leantime/leantime/issues/251)).

**k8s-test 클러스터 확인 (2026-07-07):** `My Project` (id=8)에 티켓 **9개** (task 8 + milestone 1)가 남아 있어 삭제가 차단된 상태였습니다. 설치 시 생성되는 온보딩/데모 작업일 수 있습니다.

**해결 순서:**

1. 프로젝트 보드에서 **모든 task·milestone·서브태스크** 삭제 (빈 보드여도 DB에 남아 있을 수 있음)
2. 다시 **Project Settings → Delete** 시도
3. 그래도 안 되면 **Project Settings → Status → Closed** 로 아카이브 (목록에서 숨김)
4. DB 직접 확인 (관리자만):

```bash
kubectl exec -n leantime leantime-mariadb-0 -- bash -lc \
  '/opt/bitnami/mariadb/bin/mariadb -uleantime -pleantime-k8s-test leantime \
   -e "SELECT type,COUNT(*) FROM zp_tickets WHERE projectId=8 GROUP BY type;"'
```

티켓이 0이 된 뒤에야 프로젝트 삭제가 통과합니다. 권한 문제라면 사용자 role이 **Owner/Admin** (company role)인지 확인하세요 ([권한 문서](https://support.leantime.io/en/article/leantimes-user-access-rights-breakdown-2fq3s4/)).

#### Resource sizing

| Scenario | Leantime Pod | `pm.max_children` | MariaDB |
| -------- | ------------ | ----------------- | ------- |
| k8s-test / solo | limit **2Gi**, request 512Mi | **8** | limit 512Mi |
| ~10 active users | limit **2–3Gi**, request 1Gi | **10–12** | limit **512Mi–1Gi** |

Official docs cite ~512MB minimum / 1GB recommended for the whole stack; community benchmarks report ~300–500MB RAM for ~10 active users on a tuned VPS. With PHP-FPM workers, plan for **~0.8–1.5Gi** typical and **~2Gi** peak on the app Pod. Raise `pm.max_children` before raising `memory_limit` if users see slow page loads (queueing), not OOM.

**Recovery:** If `leantime-mariadb-0` is `Pending`, check node disk pressure (`kubectl describe node … | grep DiskPressure`) and PVC binding. If MariaDB shows `ImagePullBackOff` on `docker.io/bitnami/mariadb`, Bitnami catalog brownouts may block pulls — values use [`bitnamilegacy/mariadb`](helm/values/leantime.yaml) as a fallback. If the setup wizard reappears mid-configuration, check `kubectl describe pod -n leantime -l app.kubernetes.io/name=leantime` for **`OOMKilled`** — increase `resources.limits.memory` and/or lower `php.tuning.pmMaxChildren`. DB data survives pod restarts — use `/auth/login` if users exist. If HTTPS redirects loop, confirm `app.url` is `https://leantime.k8s-test`.

### BGE-M3 embeddings (CPU TEI)

[BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3) is served via [Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference) on **CPU** so both GPUs stay available for SGLang (Gemma 4 12B). TEI exposes OpenAI-compatible `/v1/embeddings` (dense **1024-d** vectors only — no sparse/ColBERT).

```mermaid
flowchart LR
  subgraph ingest [Indexing]
    Docs[Documents / chunks] --> TEI[BGE-M3 TEI CPU]
    TEI --> Qdrant[(Qdrant)]
  end
  subgraph query [RAG query]
    Q[User question] --> TEI2[BGE-M3 TEI]
    TEI2 --> Search[Qdrant search]
    Search --> Ctx[Retrieved context]
    Ctx --> LLM[SGLang Gemma 4 12B]
    LLM --> Ans[Answer]
  end
```

| Item | Value |
| -------- | ------ |
| Namespace | `llm-serving` |
| Deployment | `bge-m3-tei` (1 replica) |
| Image | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9` |
| Model | `BAAI/bge-m3` |
| Vector size | **1024** (cosine distance in Qdrant) |
| External host | `embeddings.k8s-test` (HTTPS :443) |
| In-cluster base URL | `http://bge-m3-tei.llm-serving.svc.cluster.local:8080` |
| OpenAI path | `/v1/embeddings` |
| Legacy path | `/embed` (`{"inputs":"..."}`) |
| GPU | None (`requests`/`limits` are CPU + RAM only) |

**Files:** [`manifests/apps/bge-m3-tei.yaml`](manifests/apps/bge-m3-tei.yaml), [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml), [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml), [`scripts/test-bge-m3-tei-config.sh`](scripts/test-bge-m3-tei-config.sh), [`scripts/test-k8s-test-tls-config.sh`](scripts/test-k8s-test-tls-config.sh), [`scripts/verify-bge-m3-tei.sh`](scripts/verify-bge-m3-tei.sh).

#### Why CPU (not shared with SGLang)

| Approach | Pros | Cons |
| -------- | ---- | ---- |
| **CPU TEI (current)** | Keeps 2× GPU for Gemma; ~50 ms/query embed | Bulk indexing slower than GPU |
| GPU TEI on spare GPU | Fast indexing | Requires `replicas: 1` on SGLang or VRAM sharing |
| Same SGLang process | — | **Not supported** — one model per `sglang serve` |

#### Resource tuning (RAG chunks ≤1k tokens)

| Setting | Value | Why |
|--------|-------|-----|
| `--max-batch-tokens 1024` | batch token budget | Matches chunk size; lowers CPU RAM spikes vs default 16384 |
| `--max-client-batch-size 16` | per-request cap | Avoids CPU timeouts on large client batches |
| `--auto-truncate` | on | Truncates inputs beyond model max (8192); keep chunks ≤1000 tokens in the pipeline |
| `TOKENIZATION_WORKERS=4` | CPU cap | Prevents TEI from monopolizing all host cores |
| Dense only | TEI API | Sparse/ColBERT not exposed; use [FlagEmbedding](https://github.com/FlagOpen/FlagEmbedding) separately if needed |
| `use_fp16` | N/A on CPU | For a future GPU TEI deployment, add `--dtype float16` |

#### Deploy and verify

```bash
# Pre-deploy config gate (TDD)
./scripts/test-bge-m3-tei-config.sh

# Full stack (included in ./scripts/deploy.sh) or TEI only:
kubectl apply -f manifests/apps/bge-m3-tei.yaml

# Post-deploy verification
./scripts/verify-bge-m3-tei.sh
```

#### Connect from your machine (LAN)

Add to `/etc/hosts` (see [External access](#external-access-shared-ingress)):

```text
<NODE_IP>  embeddings.k8s-test
```

```bash
# OpenAI-compatible
curl -s https://embeddings.k8s-test/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}'

# Batch inputs
curl -s https://embeddings.k8s-test/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-m3","input":["chunk one","chunk two"]}'

# Health
curl -s https://embeddings.k8s-test/health
```

#### Connect from inside the cluster

**Pod env for RAG workloads** (e.g. in `ai-agents`):

```yaml
env:
  - name: EMBEDDING_BASE_URL
    value: "http://bge-m3-tei.llm-serving.svc.cluster.local:8080/v1"
  - name: EMBEDDING_MODEL
    value: "BAAI/bge-m3"
  - name: QDRANT_URL
    value: "http://qdrant.qdrant.svc.cluster.local:6333"
  - name: QDRANT_API_KEY
    value: "test-qdrant-api-key"
  - name: OPENAI_API_BASE
    value: "http://sglang-gemma4-12b.llm-serving.svc.cluster.local:30000/v1"
```

**OpenAI Python SDK:**

```python
from openai import OpenAI

embed_client = OpenAI(
    base_url="http://bge-m3-tei.llm-serving.svc.cluster.local:8080/v1",
    api_key="not-needed",  # TEI has no API key in this test setup
)
resp = embed_client.embeddings.create(
    model="BAAI/bge-m3",
    input="hello world",
)
vector = resp.data[0].embedding  # len == 1024
```

**LangChain:**

```python
from langchain_openai import OpenAIEmbeddings

embeddings = OpenAIEmbeddings(
    model="BAAI/bge-m3",
    openai_api_base="http://bge-m3-tei.llm-serving.svc.cluster.local:8080/v1",
    openai_api_key="not-needed",
    check_embedding_ctx_length=False,
)
vec = embeddings.embed_query("hello world")
```

#### RAG example: TEI → Qdrant → SGLang

Create a Qdrant collection with **1024** dimensions (not 384):

```python
from openai import OpenAI
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

QDRANT_URL = "http://qdrant.qdrant.svc.cluster.local:6333"
TEI_URL = "http://bge-m3-tei.llm-serving.svc.cluster.local:8080/v1"
SGLANG_URL = "http://sglang-gemma4-12b.llm-serving.svc.cluster.local:30000/v1"
COLLECTION = "rag-demo"

qdrant = QdrantClient(url=QDRANT_URL, api_key="test-qdrant-api-key")
tei = OpenAI(base_url=TEI_URL, api_key="not-needed")
llm = OpenAI(base_url=SGLANG_URL, api_key="not-needed")

qdrant.recreate_collection(
    collection_name=COLLECTION,
    vectors_config=VectorParams(size=1024, distance=Distance.COSINE),
)

chunks = ["Kubernetes schedules pods onto nodes.", "Qdrant stores dense vectors for search."]
for i, text in enumerate(chunks):
    emb = tei.embeddings.create(model="BAAI/bge-m3", input=text).data[0].embedding
    qdrant.upsert(collection_name=COLLECTION, points=[PointStruct(id=i, vector=emb, payload={"text": text})])

question = "How does scheduling work?"
q_vec = tei.embeddings.create(model="BAAI/bge-m3", input=question).data[0].embedding
hits = qdrant.search(collection_name=COLLECTION, query_vector=q_vec, limit=2)
context = "\n".join(h.payload["text"] for h in hits)

answer = llm.chat.completions.create(
    model="nmilosev/gemma-4-12B-it-quantized.w4a16",
    messages=[
        {"role": "system", "content": "Answer using the context only."},
        {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"},
    ],
)
print(answer.choices[0].message.content)
```

Off-cluster: replace URLs with `https://embeddings.k8s-test/v1`, `https://qdrant.k8s-test`, `https://sglang.k8s-test/v1`.

#### Port-forward (no ingress)

```bash
kubectl port-forward -n llm-serving svc/bge-m3-tei 8080:8080
curl -s http://127.0.0.1:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-m3","input":"test"}'
```

#### Health checks

```bash
kubectl get deploy,pods,svc,ingress -n llm-serving -l app.kubernetes.io/name=bge-m3-tei
kubectl logs -n llm-serving deploy/bge-m3-tei --tail=50
./scripts/verify-bge-m3-tei.sh
```

#### Environment variables (`verify-bge-m3-tei.sh`)

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `BGE_M3_TEI_NAMESPACE` | `llm-serving` | Target namespace |
| `BGE_M3_TEI_DEPLOY` | `bge-m3-tei` | Deployment name |
| `BGE_M3_TEI_PORT` | `8080` | Service port |
| `BGE_M3_TEI_MODEL` | `BAAI/bge-m3` | Model id for probe |
| `BGE_M3_EXPECTED_DIM` | `1024` | Expected embedding size |
| `BGE_M3_TEI_INGRESS_HOST` | `embeddings.k8s-test` | Host header for external probe |

Recovery runbook: [BGE-M3 TEI startup slow / OOM / high CPU](#bge-m3-tei-startup-slow--oom--high-cpu).

### Qdrant · NebulaGraph (path-graph)

Qdrant and NebulaGraph **install/operate** in the [path-graph](../path-graph) repo (`deploy/k8s/infra/`).

```bash
cd ../path-graph
make test-infra-config
make deploy-qdrant-nebula
make verify-qdrant-nebula
```

Runbook: [path-graph deploy/SETUP.md](../path-graph/deploy/SETUP.md#qdrant--nebulagraph).

When pairing with [BGE-M3 TEI](#bge-m3-embeddings-cpu-tei), create Qdrant collections with **`size=1024`** and `Distance.COSINE`.

| Item | In-cluster |
| -------- | ---------- |
| Qdrant REST | `http://qdrant.qdrant.svc.cluster.local:6333` |
| Qdrant external | `https://qdrant.k8s-test/` (api-key; UI `/dashboard`) |
| Nebula graphd | `nebula-graphd-svc.nebula.svc.cluster.local:9669` (`root` / `nebula`) |
| Nebula Studio | `https://nebula-studio.k8s-test/` |

### Git HTTPS server

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
https://git.k8s-test/git/<repo>.git
```

Examples:

```bash
# Clone (test credentials in URL)
git clone https://git:gitpassword@git.k8s-test/git/myrepo.git

# Or store credentials once
git clone https://git.k8s-test/git/myrepo.git
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

git clone https://git:gitpassword@git.k8s-test/git/sample.git
```

Override credentials when deploying: `GIT_HTTP_USER`, `GIT_HTTP_PASSWORD` in `scripts/deploy.sh`.

#### Build the image (first-time / after Dockerfile changes)

Chart uses `git-http-server:local` with `pullPolicy: Never` — build on the node or Mac, then import into k3s.

If the pod shows **`ErrImageNeverPull`** after disk cleanup, see [git-http-server image missing](#git-http-server-image-missing-errimageneverpull) in Recovery & troubleshooting.

**Option A — `scripts/build-git-http-server-image.sh`** (Mac Docker or SSH to node):

```bash
# Mac: start Docker first (builds linux/amd64 for the GPU node by default)
colima start
./scripts/build-git-http-server-image.sh

# Or build on the k3s node (no local Docker)
GIT_HTTP_BUILD_NODE=didim-gpu@192.168.150.200 ./scripts/build-git-http-server-image.sh
kubectl rollout restart deploy/git-http-server -n git
```

**Option B — In-cluster Kaniko** (`kubectl` only): [Recovery & troubleshooting → git-http-server image missing](#git-http-server-image-missing-errimageneverpull).

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

#### Hermes PostgreSQL registry (auto-discovery)

Hermes needs read/write access to each PostgreSQL instance’s Kubernetes **Secrets** and **ConfigMaps** (credentials, init scripts, chart configuration). RBAC already grants cluster-wide `configmaps`/`secrets` mutate; the registry tells Hermes which objects belong to which `:5432` endpoint.

| Mechanism | Purpose |
| --------- | ------- |
| **Port discovery** | `scripts/sync-hermes-pg-registry.sh` lists every Service exposing TCP `:5432` (skips ingress TCP proxy and `*-hl` headless services) |
| **Write opt-in** | Label Service or StatefulSet `k8s-test.io/hermes-pg-config: "true"` — without it, the instance is registered **read-only** |
| **Registry CM** | `ai-agents/hermes-pg-registry` → `registry.json` with `host`, `secrets[]`, `configMaps[]`, `configWritable` per instance |

New PostgreSQL Helm release checklist:

1. Add to `helm/values/<chart>.yaml`: `commonLabels.k8s-test.io/postgres-instance: "true"` and `k8s-test.io/hermes-pg-config: "true"` when Hermes should patch config.
2. Run `./scripts/sync-hermes-pg-registry.sh` (or full `./scripts/deploy.sh`) — no RBAC edit required.
3. Validate: `./scripts/test-hermes-pg-registry.sh`

For in-pod `postgresql.conf` / `pg_hba.conf` edits, Hermes uses existing `pods/exec` against the `selector` in the registry entry.

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
- **Values Overrides**: Place values files for public charts inside `helm/values/` (e.g. `ingress-nginx.yaml`, `postgresql.yaml`).

### 2. [Manifests (`/manifests`)](file:///Users/suyoo/Documents/works/test_infra/manifests/)

- **Infrastructure (`/manifests/infra`)**: Custom resources like namespaces, node configuration/affinity setup, GPU configuration, or storage classes.
- **Applications (`/manifests/apps`)**: Standard YAMLs for deploying target testing apps (Deployments, Services, Ingresses).

### 3. [Scripts (`/scripts`)](file:///Users/suyoo/Documents/works/test_infra/scripts/)

| Script | Purpose |
| ------ | ------- |
| `deploy.sh` | Full environment deploy |
| `teardown.sh` | Remove test resources |
| `test-bge-m3-tei-config.sh` | Pre-deploy TEI manifest validation |
| `test-leantime-config.sh` | Pre-deploy Leantime chart/ingress/MCP validation |
| `sync-leantime-chart.sh` | Vendor upstream Leantime Helm chart (v3.9.7) |
| `verify-bge-m3-tei.sh` | Post-deploy BGE-M3 TEI checks |
| `verify-leantime.sh` | Post-deploy Leantime + MCP setup hints |
| `verify-sglang.sh` | Post-deploy SGLang checks |

Always run from the repository root or rely on path-resolving logic inside each script.


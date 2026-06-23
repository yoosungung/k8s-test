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

### Hermes operator RBAC

`manifests/infra/hermes-k8s-operator-rbac.yaml` grants the in-cluster Hermes service account (`ai-agents/hermes-master-sa`) broad Kubernetes operator permissions for monitoring and day-to-day remediation, including PV/PVC patch/update/delete workflows, workload scale/restart/patch operations, Service/Ingress fixes, pod eviction/deletion, pod exec/port-forward for debugging, and node patch/update for cordon/uncordon-style operations.

Apply it once with cluster-admin credentials if Hermes needs to operate the cluster:

```bash
kubectl apply -f manifests/infra/hermes-k8s-operator-rbac.yaml
```

The role intentionally keeps RBAC write permissions out; Hermes can read RBAC objects but cannot grant itself or others more privileges.

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

1. **Namespaces & infra** — `manifests/infra/` (including `nebula`, `nebula-operator-system`, postgres, git, …)
2. **Helm releases** — ingress-nginx → PostgreSQL (+ pgvector) → **Qdrant** → **NebulaGraph Operator + cluster** → git-http-server → Opik
3. **Secrets** — Hugging Face, Hermes gateway/auth
4. **Apps** — `manifests/apps/` (Hermes, SGLang, **BGE-M3 TEI**, **NebulaGraph Studio**, **ingress routes** for Qdrant/Studio/…)

NebulaGraph-only reinstall (after namespaces exist):

```bash
helm repo add nebula-operator https://vesoft-inc.github.io/nebula-operator/charts
# or rely on deploy_nebula() inside deploy.sh:
NEBULA_STORAGE_CLASS=local-path ./scripts/deploy.sh --force
```

Qdrant-only reinstall (after namespace exists):

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm
helm upgrade --install qdrant qdrant/qdrant \
  -n qdrant -f helm/values/qdrant.yaml \
  --set "apiKey=${QDRANT_API_KEY:-test-qdrant-api-key}" --wait --timeout 10m
kubectl apply -f manifests/apps/ingress-routes.yaml   # qdrant.k8s-test route
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx -f helm/values/ingress-nginx.yaml --wait --timeout 15m
./scripts/verify-qdrant.sh
```

NebulaGraph Studio-only apply (after `nebula` namespace and graphd are ready):

```bash
./scripts/test-nebula-studio-config.sh
kubectl apply -f manifests/apps/nebula-studio.yaml
kubectl apply -f manifests/apps/ingress-routes.yaml   # nebula-studio.k8s-test route
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx -f helm/values/ingress-nginx.yaml --wait --timeout 15m
./scripts/verify-nebula-studio.sh
```

See [NebulaGraph](#nebulagraph) → NebulaGraph Studio for graphd connection settings.

BGE-M3 TEI-only apply (after `llm-serving` namespace and `hf-token-secret` exist):

```bash
./scripts/test-bge-m3-tei-config.sh
kubectl apply -f manifests/apps/bge-m3-tei.yaml
kubectl apply -f manifests/apps/ingress-routes.yaml   # embeddings.k8s-test route
./scripts/verify-bge-m3-tei.sh
```

See [BGE-M3 embeddings (CPU TEI)](#bge-m3-embeddings-cpu-tei) for RAG wiring and client examples.

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

**External URL not reachable:** ensure `/etc/hosts` includes `embeddings.k8s-test` and ingress-nginx exposes port `8080` ([`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml) socat sidecar). Re-upgrade if needed:

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

### NebulaGraph PVC Pending or cluster not ready

**Symptoms**

```bash
kubectl get nc -n nebula
# READY=False   or   GRAPHD-READY 0 / METAD-READY 0 / STORAGED-READY 0

kubectl get pvc -n nebula
# STATUS Pending (may be normal briefly with WaitForFirstConsumer)
```

**Cause:** StorageClass `local-path` uses `WaitForFirstConsumer` — PVCs bind only after NebulaGraph pods are scheduled. If pods stay `Pending`, the node may have `disk-pressure` taint or insufficient CPU/memory.

**Fix**

```bash
kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'
kubectl get pods -n nebula -o wide
kubectl describe pod -n nebula nebula-metad-0   # or graphd/storaged

# Reconcile via Helm if values changed
helm upgrade --install nebula nebula-operator/nebula-cluster \
  -n nebula --version 1.8.0 \
  -f helm/values/nebula-cluster.yaml \
  --set nebula.storageClassName=local-path --wait --timeout 15m

kubectl wait --for=condition=Ready nebulacluster/nebula -n nebula --timeout=300s
```

See [NebulaGraph](#nebulagraph) for connection and teardown (CRD cleanup).

### Qdrant PVC Pending or pod not ready

**Symptoms**

```bash
kubectl get pods -n qdrant
# qdrant-0   0/1   Pending

kubectl get pvc -n qdrant
# STATUS Pending (may be normal briefly with WaitForFirstConsumer)
```

**Cause:** StorageClass `local-path` uses `WaitForFirstConsumer` — the PVC binds only after `qdrant-0` is scheduled. If the pod stays `Pending`, the node may have `disk-pressure` taint or insufficient CPU/memory.

**Fix**

```bash
kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'
kubectl get pods,pvc -n qdrant -o wide
kubectl describe pod -n qdrant qdrant-0

# Reconcile via Helm if values changed
helm upgrade --install qdrant qdrant/qdrant \
  -n qdrant -f helm/values/qdrant.yaml \
  --set "apiKey=${QDRANT_API_KEY:-test-qdrant-api-key}" --wait --timeout 10m

./scripts/verify-qdrant.sh
```

See [Qdrant](#qdrant-vector-database) for connection, upgrade, and teardown.

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
| NebulaGraph | `kubectl get nc -n nebula nebula` → `READY=True` | Check PVC/Pod Pending; see [NebulaGraph](#nebulagraph) |
| NebulaGraph Studio | `kubectl get deploy -n nebula nebula-studio` → Ready | `./scripts/verify-nebula-studio.sh`; see [NebulaGraph Studio](#nebulagraph-studio) |
| Qdrant | `kubectl get pods -n qdrant` → `qdrant-0` Running | `./scripts/verify-qdrant.sh`; check PVC/Pod Pending on disk pressure |

---

## External access (shared Ingress)

Apps use **ClusterIP** Services and reach the LAN via the shared [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) controller. Host-based routing uses **`*.k8s-test`**; the URL **port matches each app’s Service port** (e.g. Opik **5173**, SGLang **30000**, Git **80**). The controller binds those ports on the node with **hostPort** (and a small socat sidecar for extra HTTP/TCP aliases), so you do not use a shared **30080** hop.

Replace `<NODE_IP>` with any cluster node (e.g. `192.168.150.200`). HTTP apps use **`http://<name>.k8s-test:<app-port>/`** — the **port is required** for most apps (Opik `5173`, Qdrant `6333`, Studio `7001`, …). Port `80` on the node is the shared ingress controller; host-based routes still work on `:80` if the Ingress resource exists, but the convention in this repo is **service port = external port** via the socat sidecar.

Add to `/etc/hosts`:

```text
<NODE_IP>  opik.k8s-test hermes.k8s-test hermes-api.k8s-test sglang.k8s-test embeddings.k8s-test qdrant.k8s-test nebula-studio.k8s-test git.k8s-test
```

| Service | Host | External URL | In-cluster |
| -------- | ------ | ------------ | ---------- |
| Ingress (HTTP/HTTPS) | — | `http://<NODE_IP>:80` / `https://<NODE_IP>:443` | — |
| PostgreSQL | — | `psql -h <NODE_IP> -p 5432 …` | `postgresql.postgres.svc.cluster.local:5432` |
| Qdrant REST / Web UI | `qdrant.k8s-test` | `http://qdrant.k8s-test:6333/` (UI: `/dashboard`) | `qdrant.qdrant.svc.cluster.local:6333` |
| Qdrant gRPC | — | `<NODE_IP>:6334` | `qdrant.qdrant.svc.cluster.local:6334` |
| Opik UI | `opik.k8s-test` | `http://opik.k8s-test:5173/` | `opik-frontend.opik.svc.cluster.local:5173` |
| Hermes dashboard | `hermes.k8s-test` | `http://hermes.k8s-test:9119/` | `hermes-master.ai-agents.svc.cluster.local:9119` |
| Hermes API | `hermes-api.k8s-test` | `http://hermes-api.k8s-test:8642/` | `hermes-master.ai-agents.svc.cluster.local:8642` |
| SGLang OpenAI | `sglang.k8s-test` | `http://sglang.k8s-test:30000/v1/` | `sglang-gemma4-12b.llm-serving.svc.cluster.local:30000` |
| BGE-M3 TEI | `embeddings.k8s-test` | `http://embeddings.k8s-test:8080/v1/embeddings` | `bge-m3-tei.llm-serving.svc.cluster.local:8080` |
| Git HTTP | `git.k8s-test` | `http://git.k8s-test:80/git/<repo>.git` | `git-http-server.git.svc.cluster.local/git/…` |
| NebulaGraph Studio | `nebula-studio.k8s-test` | `http://nebula-studio.k8s-test:7001/` | `nebula-studio.nebula.svc.cluster.local:7001` |
| NebulaGraph graphd | — | `nebula-console -addr <NODE_IP> -port <NodePort> -u root -p nebula` | `nebula-graphd-svc.nebula.svc.cluster.local:9669` |

**Ingress routing:** HTTP apps use host `*.k8s-test` rules in [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml). The ingress-nginx controller listens on node `:80`/`:443`; per-app ports (`6333`, `7001`, …) are forwarded to `:80` by the **socat** sidecar in [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml). Qdrant gRPC (`6334`) and PostgreSQL (`5432`) use **TCP stream** passthrough instead of HTTP Ingress.

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
| External host | `embeddings.k8s-test:8080` |
| In-cluster base URL | `http://bge-m3-tei.llm-serving.svc.cluster.local:8080` |
| OpenAI path | `/v1/embeddings` |
| Legacy path | `/embed` (`{"inputs":"..."}`) |
| GPU | None (`requests`/`limits` are CPU + RAM only) |

**Files:** [`manifests/apps/bge-m3-tei.yaml`](manifests/apps/bge-m3-tei.yaml), [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml), [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml) (hostPort `8080`), [`scripts/test-bge-m3-tei-config.sh`](scripts/test-bge-m3-tei-config.sh), [`scripts/verify-bge-m3-tei.sh`](scripts/verify-bge-m3-tei.sh).

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
curl -s http://embeddings.k8s-test:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}'

# Batch inputs
curl -s http://embeddings.k8s-test:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-m3","input":["chunk one","chunk two"]}'

# Health
curl -s http://embeddings.k8s-test:8080/health
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

Off-cluster: replace URLs with `http://embeddings.k8s-test:8080/v1`, `http://qdrant.k8s-test:6333`, `http://sglang.k8s-test:30000/v1`.

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

### Qdrant (vector database)

[Qdrant](https://qdrant.tech/) is a vector similarity search engine used for RAG, semantic search, and embedding storage. It is installed via the [official Helm chart](https://github.com/qdrant/qdrant-helm) when you run `./scripts/deploy.sh`.

When pairing with [BGE-M3 TEI](#bge-m3-embeddings-cpu-tei), create collections with **`size=1024`** and `Distance.COSINE`.

| Item | Value |
| -------- | ------ |
| Namespace | `qdrant` |
| Release name | `qdrant` |
| Workload | StatefulSet (`qdrant-0`) |
| Qdrant version | Chart default (currently v1.18.x) |
| StorageClass | `local-path` (8 GiB PVC) |
| REST port | `6333` (HTTP API + Web UI) |
| gRPC port | `6334` |
| External access (REST/UI) | Ingress host `qdrant.k8s-test` on port `6333` (socat → nginx) |
| External access (gRPC) | ingress-nginx TCP stream on host `:6334` |
| API key (test default) | `test-qdrant-api-key` |
| Chart version | latest from repo |

**Files:** [`helm/values/qdrant.yaml`](helm/values/qdrant.yaml), [`manifests/infra/qdrant-namespace.yaml`](manifests/infra/qdrant-namespace.yaml), [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml) (host `qdrant.k8s-test`), [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml) (socat `6333`, TCP `6334`), [`scripts/test-qdrant-config.sh`](scripts/test-qdrant-config.sh), [`scripts/verify-qdrant.sh`](scripts/verify-qdrant.sh).

Single-node test layout: **1 replica**, Raft cluster mode **disabled** (`config.cluster.enabled: false`). Suitable for local development and integration tests; not HA.

#### Environment variables (`deploy.sh`)

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `QDRANT_API_KEY` | `test-qdrant-api-key` | REST/gRPC authentication key |
| `QDRANT_CHART_VERSION` | *(empty = latest)* | Pin Helm chart version |
| `QDRANT_INGRESS_HOST` | `qdrant.k8s-test` | Host header for external ingress probe |

```bash
QDRANT_API_KEY="$(openssl rand -hex 32)" ./scripts/deploy.sh --force
```

#### Connect from inside the cluster

```bash
# REST health / list collections
curl -H "api-key: test-qdrant-api-key" \
  http://qdrant.qdrant.svc.cluster.local:6333/collections

# Web UI — open in browser (from a machine with /etc/hosts → qdrant.k8s-test)
open "http://qdrant.k8s-test:6333/dashboard"
```

#### Web UI and API key

The built-in [Qdrant Web UI](https://qdrant.tech/documentation/web-ui/) is served at **`/dashboard`** on the REST port. When `apiKey` is set (default in this environment), the UI shows **Set API Key** on first load — enter the same key as REST clients:

| Setting | Value |
| ------- | ----- |
| Default API key | `test-qdrant-api-key` |
| Override at deploy | `QDRANT_API_KEY=… ./scripts/deploy.sh --force` |
| Check deployed key | `helm get values qdrant -n qdrant \| grep -i apiKey` |

The key is stored in the browser session only; there is no separate UI password.

**Pod env for workloads** (e.g. RAG services in `ai-agents`):

```yaml
env:
  - name: QDRANT_URL
    value: "http://qdrant.qdrant.svc.cluster.local:6333"
  - name: QDRANT_API_KEY
    valueFrom:
      secretKeyRef:
        name: qdrant-credentials   # create separately for non-default keys
        key: api-key
```

#### Connect from your machine (LAN)

Add `qdrant.k8s-test` to `/etc/hosts` (see [External access](#external-access-shared-ingress)). Requires ingress-nginx with socat `6333` and Ingress route in [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml).

```bash
# REST (api-key required when auth is enabled)
curl -H "api-key: test-qdrant-api-key" \
  http://qdrant.k8s-test:6333/collections

# Web UI
open "http://qdrant.k8s-test:6333/dashboard"
```

**Python client:**

```bash
pip install qdrant-client
```

```python
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams

client = QdrantClient(
    url="http://qdrant.k8s-test:6333",
    api_key="test-qdrant-api-key",
)

# Create a collection
client.create_collection(
    collection_name="demo",
    vectors_config=VectorParams(size=384, distance=Distance.COSINE),
)

print(client.get_collections())
```

**gRPC client** (lower latency; same API key):

```python
from qdrant_client import QdrantClient

client = QdrantClient(
    host="<NODE_IP>",
    port=6334,
    api_key="test-qdrant-api-key",
    prefer_grpc=True,
)
```

#### Port-forward (no ingress-nginx TCP)

```bash
kubectl port-forward -n qdrant svc/qdrant 6333:6333 6334:6334
curl -H "api-key: test-qdrant-api-key" http://127.0.0.1:6333/collections
```

#### Validate and verify

**Before deploy** (Helm template + namespace dry-run):

```bash
chmod +x scripts/test-qdrant-config.sh scripts/verify-qdrant.sh
./scripts/test-qdrant-config.sh
```

**After deploy:**

```bash
./scripts/verify-qdrant.sh
```

#### Health checks

```bash
kubectl get sts,pods,pvc,svc -n qdrant
kubectl logs -n qdrant qdrant-0 --tail=50
curl -s -H "api-key: test-qdrant-api-key" -H "Host: qdrant.k8s-test" \
  "http://<NODE_IP>:6333/collections"
```

#### Qdrant-only reinstall

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm
helm upgrade --install qdrant qdrant/qdrant \
  -n qdrant -f helm/values/qdrant.yaml \
  --set "apiKey=${QDRANT_API_KEY:-test-qdrant-api-key}" \
  --wait --timeout 10m

# Re-apply ingress if external access is missing
kubectl apply -f manifests/apps/ingress-routes.yaml
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx -f helm/values/ingress-nginx.yaml --wait --timeout 15m

./scripts/verify-qdrant.sh
```

#### Upgrade chart / Qdrant version

```bash
helm repo update qdrant
helm upgrade qdrant qdrant/qdrant -n qdrant \
  -f helm/values/qdrant.yaml \
  --set "apiKey=${QDRANT_API_KEY:-test-qdrant-api-key}" \
  --wait --timeout 10m
```

To pin a specific Qdrant image, set `image.tag` in [`helm/values/qdrant.yaml`](helm/values/qdrant.yaml) (e.g. `v1.18.2`).

#### Teardown

`./scripts/teardown.sh` uninstalls the Helm release. To remove data PVCs as well:

```bash
helm uninstall qdrant -n qdrant
kubectl delete pvc -n qdrant -l app.kubernetes.io/instance=qdrant
```

#### Troubleshooting

| Symptom | Likely cause | Action |
| -------- | ------------- | ------ |
| `qdrant-0` Pending | Node disk-pressure taint | See [Node disk pressure](#node-disk-pressure-failedscheduling--untolerated-taint) |
| PVC Pending | `WaitForFirstConsumer`; pod not scheduled | `kubectl describe pod -n qdrant qdrant-0` |
| `401` / `403` on REST or UI | Wrong or missing `api-key` | Default: `test-qdrant-api-key`; see [Web UI and API key](#web-ui-and-api-key) |
| `404` on `qdrant.k8s-test` | Ingress route or socat `6333` not applied | `kubectl get ingress -n qdrant`; apply [`ingress-routes.yaml`](manifests/apps/ingress-routes.yaml); upgrade ingress-nginx |
| External `:6333` unreachable | ingress-nginx socat/Ingress not applied | `helm upgrade` ingress-nginx with [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml); `kubectl apply -f manifests/apps/ingress-routes.yaml` |
| Data lost after reinstall | PVC deleted | Back up snapshots before teardown; see [Qdrant snapshots](https://qdrant.tech/documentation/concepts/snapshots/) |

**PVC stays Pending:** With `local-path` and `WaitForFirstConsumer`, PVCs bind only after `qdrant-0` is scheduled. If the pod is Pending, check node taints (`kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'`).

### NebulaGraph

[NebulaGraph](https://github.com/vesoft-inc/nebula) v3.8.0 is installed via [NebulaGraph Operator](https://docs.nebula-graph.io/3.8.0/k8s-operator/) when you run `./scripts/deploy.sh`. Values: [`helm/values/nebula-operator.yaml`](helm/values/nebula-operator.yaml), [`helm/values/nebula-cluster.yaml`](helm/values/nebula-cluster.yaml).

| Item | Value |
| -------- | ------ |
| Operator namespace | `nebula-operator-system` |
| Cluster namespace | `nebula` |
| Cluster name | `nebula` |
| StorageClass | `local-path` (override: `NEBULA_STORAGE_CLASS`) |
| Chart version | `1.8.0` (override: `NEBULA_OPERATOR_CHART_VERSION`, `NEBULA_CLUSTER_CHART_VERSION`) |
| Default credentials | user `root`, password `nebula` |
| Graph port (Thrift) | `9669` (Service); NodePort assigned dynamically (e.g. `32080`) |
| Graph HTTP (status) | `19669` (Service); NodePort assigned dynamically |
| NebulaGraph Studio | Ingress `nebula-studio.k8s-test:7001` (v3.8.0 web GUI) |

Single-node test layout: graphd/metad/storaged each **1 replica**, PVCs on `local-path` (~8–9 GiB total). Namespaces: [`manifests/infra/nebula-namespace.yaml`](manifests/infra/nebula-namespace.yaml), [`manifests/infra/nebula-operator-namespace.yaml`](manifests/infra/nebula-operator-namespace.yaml).

#### NebulaGraph Studio

[NebulaGraph Studio](https://docs.nebula-graph.io/3.8.0/nebula-studio/) is Vesoft’s official web GUI for schema design, data import, and nGQL. Deployed from [`manifests/apps/nebula-studio.yaml`](manifests/apps/nebula-studio.yaml) (image `vesoft/nebula-graph-studio:v3.8.0`, sqlite3 metadata on PVC).

| Item | Value |
| -------- | ------ |
| Namespace | `nebula` |
| Ingress host | `nebula-studio.k8s-test` |
| External URL | `http://nebula-studio.k8s-test:7001/` |
| In-cluster URL | `http://nebula-studio.nebula.svc.cluster.local:7001/` |
| Service port | `7001` |

Add `nebula-studio.k8s-test` to `/etc/hosts` (see [External access](#external-access-shared-ingress)). **Use port `7001`** — other apps in this cluster follow the same pattern (`opik.k8s-test:5173`, `qdrant.k8s-test:6333`, …). Port `80` without the app port may return nginx `404` if the Ingress rule is missing.

**Connect Studio to graphd** (Config Server screen):

| Field | Value |
| ----- | ----- |
| Host | `nebula-graphd-svc.nebula.svc.cluster.local` (browser on LAN: `<NODE_IP>`) |
| Port | `9669` (LAN: graphd NodePort, e.g. `32080` — `kubectl get svc -n nebula nebula-graphd-svc`) |
| User / password | `root` / `nebula` |

```bash
./scripts/test-nebula-studio-config.sh
./scripts/verify-nebula-studio.sh
kubectl get deploy,ingress -n nebula nebula-studio
```

| Symptom | Likely cause | Action |
| -------- | ------------- | ------ |
| `404` on `http://nebula-studio.k8s-test` | Wrong port or Ingress not applied | Use **`:7001`**; `kubectl apply -f manifests/apps/nebula-studio.yaml -f manifests/apps/ingress-routes.yaml` |
| `404` on `:7001` | socat `7001` missing on ingress-nginx | `helm upgrade` with [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml) |
| Studio pod Pending | PVC / disk pressure | `kubectl describe pod -n nebula -l app=nebula-studio` |
| Cannot connect to graphd in UI | Wrong host/port from browser | Use node IP + graphd **NodePort**, not in-cluster DNS, when browsing from your laptop |

**Files:** [`manifests/apps/nebula-studio.yaml`](manifests/apps/nebula-studio.yaml), [`manifests/apps/ingress-routes.yaml`](manifests/apps/ingress-routes.yaml), [`helm/values/ingress-nginx.yaml`](helm/values/ingress-nginx.yaml) (socat `7001`), [`scripts/test-nebula-studio-config.sh`](scripts/test-nebula-studio-config.sh), [`scripts/verify-nebula-studio.sh`](scripts/verify-nebula-studio.sh).

**Connect from inside the cluster (CLI):**

```bash
kubectl run nebula-console --rm -it --restart=Never \
  --image vesoft/nebula-console:v3.8.0 -n nebula -- \
  nebula-console -addr nebula-graphd-svc.nebula.svc.cluster.local -port 9669 -u root -p nebula
```

Non-interactive smoke test:

```bash
kubectl run nebula-console-test --restart=Never \
  --image vesoft/nebula-console:v3.8.0 -n nebula -- \
  nebula-console -addr nebula-graphd-svc.nebula.svc.cluster.local -port 9669 -u root -p nebula -e 'SHOW HOSTS;'
kubectl logs nebula-console-test -n nebula
kubectl delete pod nebula-console-test -n nebula
```

**Connect from your machine (NodePort):**

```bash
NODE_PORT="$(kubectl get svc -n nebula nebula-graphd-svc -o jsonpath='{.spec.ports[?(@.name=="thrift")].nodePort}')"
nebula-console -addr 192.168.150.200 -port "${NODE_PORT}" -u root -p nebula
```

**Health checks:**

```bash
kubectl get nc -n nebula
kubectl get pods -n nebula-operator-system
kubectl get pods -n nebula
kubectl get pvc -n nebula
```

**PVC stays Pending:** With `local-path` and `WaitForFirstConsumer`, PVCs bind only after NebulaGraph pods are scheduled. If pods are Pending, check node taints (`kubectl describe node didim-gpu | grep -E 'Taints|DiskPressure'`).

**Teardown:** `./scripts/teardown.sh` removes the cluster and operator Helm releases. CRDs may remain; to remove them:

```bash
kubectl delete crd \
  nebulaclusters.apps.nebula-graph.io \
  nebulaautoscalers.autoscaling.nebula-graph.io \
  nebularestores.apps.nebula-graph.io \
  nebulabackups.apps.nebula-graph.io \
  nebulacronbackups.apps.nebula-graph.io
```

**Docs:** [Install Operator](https://docs.nebula-graph.io/3.8.0/k8s-operator/2.get-started/2.1.install-operator/) · [Create cluster](https://docs.nebula-graph.io/3.8.0/k8s-operator/2.get-started/2.3.create-cluster/)

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
- **Values Overrides**: Place values files for public charts inside `helm/values/` (e.g. `ingress-nginx.yaml`, `postgresql.yaml`, `qdrant.yaml`, `nebula-operator.yaml`, `nebula-cluster.yaml`).

### 2. [Manifests (`/manifests`)](file:///Users/suyoo/Documents/works/test_infra/manifests/)

- **Infrastructure (`/manifests/infra`)**: Custom resources like namespaces, node configuration/affinity setup, GPU configuration, or storage classes.
- **Applications (`/manifests/apps`)**: Standard YAMLs for deploying target testing apps (Deployments, Services, Ingresses).

### 3. [Scripts (`/scripts`)](file:///Users/suyoo/Documents/works/test_infra/scripts/)

| Script | Purpose |
| ------ | ------- |
| `deploy.sh` | Full environment deploy |
| `teardown.sh` | Remove test resources |
| `test-bge-m3-tei-config.sh` | Pre-deploy TEI manifest validation |
| `verify-bge-m3-tei.sh` | Post-deploy BGE-M3 TEI checks |
| `test-qdrant-config.sh` | Pre-deploy Qdrant Helm validation |
| `verify-qdrant.sh` | Post-deploy Qdrant checks |
| `verify-sglang.sh` | Post-deploy SGLang checks |

Always run from the repository root or rely on path-resolving logic inside each script.


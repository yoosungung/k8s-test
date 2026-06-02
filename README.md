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

## NodePort Services (External Access)

Some services are exposed outside the cluster via **NodePort**. Replace `<NODE_IP>` with any cluster node address (for example, the test node `192.168.150.200`).


| Service              | Namespace     | NodePort          | In-cluster port | Config source                                                                                                                                                | Access example                                     |
| -------------------- | ------------- | ----------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| PostgreSQL           | `postgres`    | **30432**         | 5432            | `[helm/values/postgresql.yaml](helm/values/postgresql.yaml)`                                                                                                 | `psql -h <NODE_IP> -p 30432 -U hermes -d hermesdb` |
| SGLang (gemma-4-31B) | `llm-serving` | **30300**         | 30000           | `[manifests/apps/sglang-gemma4-31b.yaml](manifests/apps/sglang-gemma4-31b.yaml)`                                                                             | `curl http://<NODE_IP>:30300/v1/models`            |
| Hermes dashboard     | `ai-agents`   | **30119**         | 9119            | `[manifests/apps/hermes-master.yaml](manifests/apps/hermes-master.yaml)`, `[manifests/apps/hermes-wiki-master.yaml](manifests/apps/hermes-wiki-master.yaml)` | `http://<NODE_IP>:30119`                           |
| Hermes API           | `ai-agents`   | *(auto-assigned)* | 8642            | `[manifests/apps/hermes-master.yaml](manifests/apps/hermes-master.yaml)`                                                                                     | See note below                                     |
| Opik UI              | `opik`        | **30517**         | 5173            | `[helm/values/opik.yaml](helm/values/opik.yaml)`, `[scripts/deploy.sh](scripts/deploy.sh)`                                                                  | `http://<NODE_IP>:30517`                           |


### Opik (agent tracing / experiments)

[Opik](https://github.com/comet-ml/opik) is installed via Helm when you run `./scripts/deploy.sh`. The UI is exposed on NodePort **30517**. Self-hosted Opik has **no built-in authentication**—use only on trusted test networks.

Trace from your machine or agents:

```bash
export OPIK_URL_OVERRIDE="http://<NODE_IP>:30517/api"
export OPIK_WORKSPACE="default"
pip install opik
opik configure --use_local
```

From pods inside the cluster:

```bash
export OPIK_URL_OVERRIDE="http://opik-frontend.opik.svc.cluster.local:5173/api"
```

Override the chart image tag with `OPIK_VERSION` (default `latest`), e.g. `OPIK_VERSION=2.0.18 ./scripts/deploy.sh`.

### PostgreSQL credentials (test defaults)

Defined in `[helm/values/postgresql.yaml](helm/values/postgresql.yaml)`:


| User       | Database   | Password         |
| ---------- | ---------- | ---------------- |
| `hermes`   | `hermesdb` | `hermespassword` |
| `postgres` | *(admin)*  | `adminpassword`  |


The `hermesdb` database is initialized with the **pgvector** extension.

### Hermes API NodePort

Only the Hermes **dashboard** port is pinned to `30119`. The API port (`8642`) receives a **Kubernetes-assigned** NodePort (it changes if the Service is recreated). Look it up after deploy:

```bash
kubectl get svc hermes-master -n ai-agents -o jsonpath='{.spec.ports[?(@.name=="api")].nodePort}{"\n"}'
```

### Verify NodePorts

```bash
kubectl get svc -A -o wide | grep NodePort
```

If Opik UI on `30517` refuses connection, confirm the assigned port (Helm may leave a random NodePort until `deploy.sh` patches it):

```bash
kubectl get svc opik-frontend -n opik -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
# Fix to 30517:
kubectl patch svc opik-frontend -n opik --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30517}]'
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


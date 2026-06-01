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


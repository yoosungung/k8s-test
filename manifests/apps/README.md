# Application Manifests (`/manifests/apps`)

This directory contains raw Kubernetes manifests for application workloads running in the test environment.

## Deployed applications (via `deploy.sh`)

| Manifest | Namespace | Purpose | Verify script |
| -------- | ----------- | ------- | ------------- |
| `sglang-gemma4-12b.yaml` | `llm-serving` | Gemma 4 12B LLM (2× GPU) | `scripts/verify-sglang.sh` |
| `bge-m3-tei.yaml` | `llm-serving` | BAAI/bge-m3 dense embeddings (CPU TEI) | `scripts/test-bge-m3-tei-config.sh`, `scripts/verify-bge-m3-tei.sh` |
| `ingress-routes.yaml` | various | Shared `*.k8s-test` Ingress routes managed by this repo (HTTPS :443) | `scripts/test-k8s-test-tls-config.sh`, `scripts/test-leantime-config.sh` |
| `hermes-*.yaml` | `ai-agents` | Hermes agent stack | — |
| `hf-secret.yaml` | `llm-serving` | Placeholder Hugging Face token (template) | — |

Full operational docs: [`README.md`](../README.md) → External access, BGE-M3 TEI, SGLang. Nebula/path-graph-specific routes are managed outside this repo; Qdrant is not a `k8s-test` operating target.

## Target components

- **Deployments / StatefulSets**: Application core runtimes.
- **Services**: Network abstractions exposing applications.
- **Ingress**: External routing rules for services (`ingress-routes.yaml`; Git uses chart Ingress).
- **ConfigMaps & Secrets**: Configuration parameters and sensitive credentials.

## Guidelines

1. Make sure secrets are either template-based (e.g. sample secrets) or retrieved from a secure secret store (never check in real credentials to git).
2. Group related apps into subfolders if the repository grows (e.g., `manifests/apps/frontend/`, `manifests/apps/backend/`).
3. Always label resources clearly with `app.kubernetes.io/name` for monitoring and debugging.
4. When adding a new app manifest, update `scripts/deploy.sh` flow (if ordering matters), `README.md`, and add `scripts/test-*.sh` / `scripts/verify-*.sh` where applicable.

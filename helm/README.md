# Helm Configurations (`/helm`)

This directory is dedicated to Helm charts and release configuration values.

## Structure

- **`charts/`**: Store custom Helm charts created for your workloads here.
- **`values/`**: Overrides for official/public Helm charts should be stored here as `<release-or-chart-name>.yaml` (e.g. `ingress-nginx.yaml`, `postgresql.yaml`).

## Installed third-party charts (via `deploy.sh`)

| Release | Chart | Values file | Verify script |
| -------- | ----- | ------------- | ------------- |
| `ingress-nginx` | `ingress-nginx/ingress-nginx` | `helm/values/ingress-nginx.yaml` | `scripts/test-k8s-test-tls-config.sh` (HTTPS :443, mkcert TLS) |
| `postgresql` | `bitnami/postgresql` | `helm/values/postgresql.yaml` | — |
| `git-http-server` | `helm/charts/git-http-server` | `helm/values/git-http-server.yaml` | — |
| `opik` | `opik/opik` | `helm/values/opik.yaml` | — |

NebulaGraph/path-graph Helm values, when needed, are managed by the sibling [path-graph](../path-graph) repo. Qdrant is not installed or operated by `k8s-test`.

Validate BGE-M3 TEI manifest before apply (raw Deployment, not Helm):

```bash
./scripts/test-bge-m3-tei-config.sh
```

## Guidelines

1. **Installing Public Charts**:
   If you need to install a public helm chart, do not download the chart locally. Instead:
   - Add the repo and install function in `/scripts/deploy.sh` (and uninstall in `/scripts/teardown.sh`).
   - Create a corresponding override file in `/helm/values/<chart-name>.yaml`.
   - Install using `helm upgrade --install <release> <repo>/<chart> -f helm/values/<chart-name>.yaml`.

2. **Linting Custom Charts**:
   Before pushing changes to a custom chart in `/helm/charts/`, run:
   ```bash
   helm lint helm/charts/<your-chart>
   ```

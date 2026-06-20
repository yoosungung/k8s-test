# Helm Configurations (`/helm`)

This directory is dedicated to Helm charts and release configuration values.

## Structure

- **`charts/`**: Store custom Helm charts created for your workloads here.
- **`values/`**: Overrides for official/public Helm charts should be stored here as `<release-or-chart-name>.yaml` (e.g. `nebula-operator.yaml`, `nebula-cluster.yaml`).

## Installed third-party charts (via `deploy.sh`)

| Release | Chart | Values file |
| -------- | ----- | ------------- |
| `ingress-nginx` | `ingress-nginx/ingress-nginx` | `helm/values/ingress-nginx.yaml` |
| `postgresql` | `bitnami/postgresql` | `helm/values/postgresql.yaml` |
| `nebula-operator` | `nebula-operator/nebula-operator` | `helm/values/nebula-operator.yaml` |
| `nebula` | `nebula-operator/nebula-cluster` | `helm/values/nebula-cluster.yaml` |
| `git-http-server` | `helm/charts/git-http-server` | `helm/values/git-http-server.yaml` |
| `opik` | `opik/opik` | `helm/values/opik.yaml` |

Validate NebulaGraph values before install:

```bash
helm repo add nebula-operator https://vesoft-inc.github.io/nebula-operator/charts
helm template nebula nebula-operator/nebula-cluster \
  --version 1.8.0 -f helm/values/nebula-cluster.yaml \
  --set nebula.storageClassName=local-path
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

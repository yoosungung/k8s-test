# Helm Configurations (`/helm`)

This directory is dedicated to Helm charts and release configuration values.

## Structure

- **`charts/`**: Store custom Helm charts created for your workloads here.
- **`values/`**: Overrides for official/public Helm charts should be stored here as `<release-or-chart-name>-values.yaml`.

## Guidelines

1. **Installing Public Charts**:
   If you need to install a public helm chart, do not download the chart locally. Instead:
   - Add the repo in `/scripts/deploy.sh`.
   - Create a corresponding override file in `/helm/values/<chart-name>-values.yaml`.
   - Install using `helm upgrade --install <release> <repo>/<chart> -f helm/values/<chart-name>-values.yaml`.

2. **Linting Custom Charts**:
   Before pushing changes to a custom chart in `/helm/charts/`, run:
   ```bash
   helm lint helm/charts/<your-chart>
   ```

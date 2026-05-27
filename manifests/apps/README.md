# Application Manifests (`/manifests/apps`)

This directory contains raw Kubernetes manifests for application workloads running in the test environment.

## Target Components
- **Deployments / StatefulSets**: Application core runtimes.
- **Services**: Network abstractions exposing applications.
- **Ingress**: External routing rules for services.
- **ConfigMaps & Secrets**: Configuration parameters and sensitive credentials.

## Guidelines

1. Make sure secrets are either template-based (e.g. sample secrets) or retrieved from a secure secret store (never check in real credentials to git).
2. Group related apps into subfolders if the repository grows (e.g., `manifests/apps/frontend/`, `manifests/apps/backend/`).
3. Always label resources clearly with `app.kubernetes.io/name` for monitoring and debugging.

# Infrastructure Manifests (`/manifests/infra`)

This directory contains raw Kubernetes manifests responsible for setting up base infrastructure services and configurations.

## Target Components
- **Namespaces**: Core namespace configurations (`postgres`, `git`, `ingress-nginx`, …). Nebula/path-graph namespaces are managed outside this repo. Qdrant is not a `k8s-test` operating target.
- **Node Configurations**: GPU node settings, node label configurations, node affinities, and taints.
- **Storage**: PersistentVolumes, PersistentVolumeClaims, and StorageClasses.
- **Security & RBAC**: Roles, RoleBindings, ClusterRoles, ClusterRoleBindings, and ServiceAccounts for infra services.

## Guidelines

1. Ensure configurations here are applied **first** (before application deployments).
2. Avoid hardcoding environment-specific properties if possible.
3. Validate manifests with:
   ```bash
   kubectl apply --dry-run=client -f <file>
   ```

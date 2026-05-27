# AI Agent Guidelines for Kubernetes Test Infrastructure

This file contains guidelines, instructions, and context for AI coding agents (such as Antigravity) working on this repository. Please read this file carefully before performing any modifications.

---

## 1. Project Overview
This repository manages configurations, Helm charts, raw Kubernetes manifests, and utility scripts for building, updating, and cleaning up a local or remote Kubernetes test environment.

---

## 2. Directory Layout and Conventions

Ensure all new files conform to the following directory layout:

* **`/helm`**: All Helm-related configurations.
  * `/helm/charts/`: Custom helm charts created specifically for this test environment.
  * `/helm/values/`: Value overrides for third-party helm charts (e.g. ingress-nginx, postgresql).
* **`/manifests`**: Raw Kubernetes YAML manifests.
  * `/manifests/infra/`: Infrastructure-level manifests (e.g. Namespaces, StorageClasses, CRDs, GPU/Node configurations).
  * `/manifests/apps/`: Application-level manifests (e.g. Deployments, Services, ConfigMaps, Secrets).
* **`/scripts`**: Orchestration and automation shell scripts (`.sh`).
  * `/scripts/deploy.sh`: Unified script to apply all manifests and Helm charts.
  * `/scripts/teardown.sh`: Unified script to safely clean up the test environment.

### Naming Conventions
* **Files**: Lowercase, hyphen-separated (e.g., `ingress-controller.yaml`, `deploy-app.sh`).
* **Kubernetes Resources**: Names should use kebab-case (`my-test-service`) and include appropriate labels (e.g., `app.kubernetes.io/name`).
* **Namespace**: Do not hardcode namespaces in manifests if they can be applied via context, unless deploying to system-wide namespaces (like `kube-system`). Otherwise, explicitly declare them or manage them in `deploy.sh`.

---

## 3. Tool and Command Execution Guidelines

* **Cluster Operations**:
  * Before modifying any resources directly on the cluster, check current context using `kubectl config current-context` to prevent accidental production deployments.
  * Prefer `helm list -A` or `kubectl get ns` to check current resources instead of assuming status.
* **Testing Changes**:
  * Always use dry-run mode when validating YAML files:
    ```bash
    kubectl apply --dry-run=client -f <file>
    ```
  * Always validate Helm values overrides:
    ```bash
    helm template <release-name> <chart-name> -f <values-file>
    ```

---

## 4. Updates & Maintenance
* When adding a new Helm chart or raw manifest, ensure it is added to `/scripts/deploy.sh` and `/scripts/teardown.sh` in the correct order of dependencies (e.g. namespaces first, then CRDs, then infrastructure, then applications).
* Ensure `README.md` is updated if there are new prerequisites or manual steps required.

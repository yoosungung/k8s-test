#!/usr/bin/env python3
"""Build Hermes PostgreSQL registry JSON from cluster objects or a fixture List."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PG_PORT = 5432
SKIP_SERVICE_NAMES = {"ingress-nginx-controller"}
POOLER_NAME_RE = re.compile(r"pgbouncer", re.I)
PG_SECRET_NAME_RE = re.compile(
    r"(^|[-_/])(postgresql|postgres)([-_/]|$)|postgres[-_]?credentials",
    re.I,
)
PG_CONFIGMAP_NAME_RE = re.compile(
    r"(postgresql|postgres)[-_]?(configuration|config|init|extended)|^db-migrations$",
    re.I,
)


def labels(obj: dict) -> dict:
    return (obj.get("metadata") or {}).get("labels") or {}


def has_pg_port(svc: dict) -> bool:
    for port in (svc.get("spec") or {}).get("ports") or []:
        if port.get("port") == PG_PORT or port.get("targetPort") == PG_PORT:
            return True
    return False


def is_pooler(svc: dict) -> bool:
    name = (svc.get("metadata") or {}).get("name", "")
    if POOLER_NAME_RE.search(name):
        return True
    return labels(svc).get("k8s-test.io/postgres-role") == "pooler"


def classify_role(svc: dict) -> str:
    if is_pooler(svc):
        return "pooler"
    svc_labels = labels(svc)
    if svc_labels.get("k8s-test.io/postgres-role"):
        return svc_labels["k8s-test.io/postgres-role"]
    name = (svc.get("metadata") or {}).get("name", "")
    if name.endswith("-hl"):
        return "headless"
    return "primary"


def should_register_service(svc: dict) -> bool:
    meta = svc.get("metadata") or {}
    name = meta.get("name", "")
    if name in SKIP_SERVICE_NAMES:
        return False
    if not has_pg_port(svc):
        return False
    if classify_role(svc) == "headless":
        return False
    return True


def secret_allowed(secret: dict) -> bool:
    meta = secret.get("metadata") or {}
    name = meta.get("name", "")
    if name.startswith("sh.helm.release."):
        return False
    secret_labels = labels(secret)
    if secret_labels.get("k8s-test.io/postgres-instance") == "true":
        return True
    return bool(PG_SECRET_NAME_RE.search(name))


def configmap_allowed(cm: dict) -> bool:
    meta = cm.get("metadata") or {}
    name = meta.get("name", "")
    cm_labels = labels(cm)
    if cm_labels.get("k8s-test.io/hermes-pg-config") == "true":
        return True
    if cm_labels.get("k8s-test.io/postgres-instance") == "true":
        return True
    return bool(PG_CONFIGMAP_NAME_RE.search(name))


def namespace_sts_writable(namespace: str, statefulsets: list[dict]) -> bool:
    for sts in statefulsets:
        meta = sts.get("metadata") or {}
        if meta.get("namespace") != namespace:
            continue
        if labels(sts).get("k8s-test.io/hermes-pg-config") == "true":
            return True
    return False


def service_writable(svc: dict, statefulsets: list[dict]) -> bool:
    if labels(svc).get("k8s-test.io/hermes-pg-config") == "true":
        return True
    meta = svc.get("metadata") or {}
    return namespace_sts_writable(meta.get("namespace", ""), statefulsets)


def load_cluster_objects(input_path: Path | None, live: bool) -> list[dict]:
    if live:
        def kubectl_json(resource: str) -> dict:
            out = subprocess.check_output(
                ["kubectl", "get", resource, "-A", "-o", "json"], text=True
            )
            return json.loads(out)

        services = kubectl_json("svc")
        secrets = kubectl_json("secret")
        configmaps = kubectl_json("configmap")
        try:
            statefulsets = kubectl_json("statefulset")
        except subprocess.CalledProcessError:
            statefulsets = {"items": []}
        return (
            services["items"]
            + secrets["items"]
            + configmaps["items"]
            + statefulsets["items"]
        )

    raw = json.loads(input_path.read_text())
    return raw.get("items", raw if isinstance(raw, list) else [])


def build_registry(items: list[dict]) -> dict:
    services = [o for o in items if o.get("kind") == "Service"]
    secrets = [o for o in items if o.get("kind") == "Secret"]
    configmaps = [o for o in items if o.get("kind") == "ConfigMap"]
    statefulsets = [o for o in items if o.get("kind") == "StatefulSet"]

    instances = []
    for svc in sorted(
        services,
        key=lambda s: (
            (s.get("metadata") or {}).get("namespace", ""),
            (s.get("metadata") or {}).get("name", ""),
        ),
    ):
        if not should_register_service(svc):
            continue
        meta = svc.get("metadata") or {}
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        host = f"{name}.{ns}.svc.cluster.local"

        ns_secrets = sorted(
            (s.get("metadata") or {}).get("name", "")
            for s in secrets
            if (s.get("metadata") or {}).get("namespace") == ns and secret_allowed(s)
        )
        ns_configmaps = sorted(
            (c.get("metadata") or {}).get("name", "")
            for c in configmaps
            if (c.get("metadata") or {}).get("namespace") == ns and configmap_allowed(c)
        )

        instances.append(
            {
                "id": f"{ns}/{name}",
                "namespace": ns,
                "service": name,
                "host": host,
                "port": PG_PORT,
                "role": classify_role(svc),
                "selector": (svc.get("spec") or {}).get("selector") or {},
                "configWritable": service_writable(svc, statefulsets),
                "secrets": ns_secrets,
                "configMaps": ns_configmaps,
                "labels": labels(svc),
            }
        )

    return {
        "version": 1,
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "generatedBy": "scripts/lib/build-hermes-pg-registry.py",
        "convention": {
            "discovery": "All Services exposing TCP :5432 (except ingress TCP proxies / -hl headless)",
            "configWriteOptIn": "Label Service or StatefulSet with k8s-test.io/hermes-pg-config=true",
            "instanceLabel": "k8s-test.io/postgres-instance=true on Secrets/ConfigMaps (optional)",
        },
        "instances": instances,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="kubectl List JSON fixture")
    parser.add_argument("--live", action="store_true", help="Discover from live cluster")
    args = parser.parse_args()
    if bool(args.input) == bool(args.live):
        parser.error("Specify exactly one of --input or --live")

    items = load_cluster_objects(args.input, args.live)
    print(json.dumps(build_registry(items), indent=2, sort_keys=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

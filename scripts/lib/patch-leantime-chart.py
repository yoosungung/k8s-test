#!/usr/bin/env python3
"""Apply k8s-test patches to the upstream Leantime Helm chart."""
from __future__ import annotations

import pathlib
import sys

LEAN_APP_URL_BLOCK = """
          {{- if .Values.app.url }}
          - name: LEAN_APP_URL
            value: {{ .Values.app.url | quote }}
          {{- end }}"""

PROBE_BLOCK = """
          livenessProbe:
            httpGet:
              path: /favicon.ico
              port: http
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /favicon.ico
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6"""

EMAIL_PASSWORD_BLOCK = """
          - name: LEAN_EMAIL_SMTP_PASSWORD
            {{- if .Values.app.email.smtp.existingSecret }}
            valueFrom:
              secretKeyRef:
                name: {{ .Values.app.email.smtp.existingSecret }}
                key: {{ .Values.app.email.smtp.secretKey | default "password" }}
            {{- else }}
            value: {{ .Values.app.email.smtp.password }}
            {{- end }}"""

APP_URL_VALUES = (
    '  # -- Public base URL (required behind ingress-nginx + TLS)\n'
    '  url: ""\n'
)


def patch_values(values_path: pathlib.Path) -> None:
    text = values_path.read_text()
    if "  url:" in text:
        return
    needle = '  defaultTimezone: "America/Los_Angeles"\n'
    if needle not in text:
        raise SystemExit(f"Could not locate defaultTimezone in {values_path}")
    values_path.write_text(text.replace(needle, needle + APP_URL_VALUES))


def patch_deployment(deployment_path: pathlib.Path) -> None:
    text = deployment_path.read_text()
    if "LEAN_APP_URL" not in text:
        needle = (
            "          - name: LEAN_DEFAULT_TIMEZONE\n"
            "            value: {{ .Values.app.defaultTimezone }}\n"
        )
        if needle not in text:
            raise SystemExit(f"Could not locate LEAN_DEFAULT_TIMEZONE block in {deployment_path}")
        text = text.replace(needle, needle + LEAN_APP_URL_BLOCK + "\n")

    old_probes = (
        "          livenessProbe:\n"
        "            httpGet:\n"
        "              path: /\n"
        "              port: http\n"
        "          readinessProbe:\n"
        "            httpGet:\n"
        "              path: /\n"
        "              port: http\n"
    )
    if old_probes in text:
        text = text.replace(old_probes, PROBE_BLOCK + "\n")
    elif "/favicon.ico" not in text:
        raise SystemExit(f"Could not patch probes in {deployment_path}")

    old_password = (
        "          - name: LEAN_EMAIL_SMTP_PASSWORD\n"
        "            value: {{ .Values.app.email.smtp.password }}\n"
    )
    if old_password in text:
        text = text.replace(old_password, EMAIL_PASSWORD_BLOCK + "\n")
    elif "app.email.smtp.existingSecret" not in text:
        raise SystemExit(f"Could not patch SMTP password block in {deployment_path}")

    deployment_path.write_text(text)


def patch_chart_yaml(chart_yaml: pathlib.Path) -> None:
    text = chart_yaml.read_text()
    updated = text.replace("version: 11.5.3", "version: 20.5.3")
    if updated == text:
        if "version: 20.5.3" not in text:
            raise SystemExit(f"Could not bump MariaDB dependency in {chart_yaml}")
        return
    chart_yaml.write_text(updated)


def main() -> None:
    chart_dir = pathlib.Path(sys.argv[1])
    patch_values(chart_dir / "values.yaml")
    patch_deployment(chart_dir / "templates" / "deployment.yaml")
    patch_chart_yaml(chart_dir / "Chart.yaml")


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# TDD gate: shared postgres Helm memory (limit 4Gi / request 2Gi). Ticket #775.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${ROOT_DIR}/helm/values/postgresql.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

[[ -f "${VALUES_FILE}" ]] || fail "Missing ${VALUES_FILE}"

python3 - "${VALUES_FILE}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
primary = re.search(r"(?ms)^primary:\n(.*?)(?=^[^\s#]|\Z)", text)
if not primary:
    raise SystemExit("primary: block not found in postgresql.yaml")
resources = re.search(r"(?ms)^  resources:\n(.*?)(?=^  [^\s]|\Z)", primary.group(1))
if not resources:
    raise SystemExit("primary.resources block not found")
block = resources.group(1)
limits_mem = re.search(r"(?ms)^    limits:.*?^      memory:\s+(\S+)", block)
requests_mem = re.search(r"(?ms)^    requests:.*?^      memory:\s+(\S+)", block)
if not limits_mem or not requests_mem:
    raise SystemExit("could not parse primary.resources limits/requests memory")
limit, request = limits_mem.group(1), requests_mem.group(1)
if limit != "4Gi":
    raise SystemExit(f"primary.resources.limits.memory must be 4Gi, got {limit}")
if request != "2Gi":
    raise SystemExit(f"primary.resources.requests.memory must be 2Gi, got {request}")
print(f"helm values memory ok: limit={limit} request={request}")
PY
ok "helm/values/postgresql.yaml memory is 4Gi / 2Gi"

ok "All PostgreSQL resource tests passed"

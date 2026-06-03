#!/usr/bin/env bash
# Post-deploy checks for SGLang (gemma-4-31B). See manifests/apps/sglang-gemma4-31b.yaml.
set -euo pipefail

NAMESPACE="${SGLANG_NAMESPACE:-llm-serving}"
DEPLOY="${SGLANG_DEPLOY:-sglang-gemma4-31b}"
MIN_MAX_TOTAL_TOKENS="${SGLANG_MIN_MAX_TOTAL_TOKENS:-8192}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "Context: $(kubectl config current-context)"
echo "Waiting for rollout..."
kubectl rollout status "deploy/${DEPLOY}" -n "${NAMESPACE}" --timeout=900s

pod="$(kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOY}" -o jsonpath='{.items[0].metadata.name}')"
echo "Pod: ${pod}"

echo ""
echo "=== Launch args (context-length, tp/dp, cuda-graph) ==="
kubectl get deploy "${DEPLOY}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].command}' | python3 -m json.tool

echo ""
echo "=== Startup memory / KV pool (from logs) ==="
log_line="$(kubectl logs -n "${NAMESPACE}" "deploy/${DEPLOY}" 2>/dev/null | grep 'max_total_num_tokens=' | tail -1 || true)"
if [ -z "${log_line}" ]; then
  warn "No max_total_num_tokens line yet (server still loading?). Tail logs:"
  kubectl logs -n "${NAMESPACE}" "deploy/${DEPLOY}" --tail=30
  exit 1
fi
echo "${log_line}"

max_tokens="$(echo "${log_line}" | sed -n 's/.*max_total_num_tokens=\([0-9]*\).*/\1/p')"
avail_mem="$(echo "${log_line}" | sed -n 's/.*available_gpu_mem=\([^,]*\).*/\1/p')"

if [ -n "${max_tokens}" ] && [ "${max_tokens}" -ge "${MIN_MAX_TOTAL_TOKENS}" ]; then
  ok "max_total_num_tokens=${max_tokens} (>= ${MIN_MAX_TOTAL_TOKENS})"
else
  fail "max_total_num_tokens=${max_tokens:-unknown} is below ${MIN_MAX_TOTAL_TOKENS}"
fi

if [ -n "${avail_mem}" ]; then
  echo "available_gpu_mem=${avail_mem} (SGLang recommends ~5–8 GB after startup)"
fi

echo ""
echo "=== Recent truncation (should be empty after fix) ==="
trunc="$(kubectl logs -n "${NAMESPACE}" "deploy/${DEPLOY}" --tail=2000 2>/dev/null | grep -i Truncated || true)"
if [ -z "${trunc}" ]; then
  ok "No Truncated lines in last 2000 log lines"
else
  warn "Found Truncated entries:"
  echo "${trunc}" | tail -5
fi

echo ""
echo "=== Tool calling (OpenAI tool_calls, not raw <|tool_call> text) ==="
node_ip="${NODE_IP:-192.168.150.200}"
ingress_port="${SGLANG_HTTP_PORT:-30000}"
sglang_host="${SGLANG_INGRESS_HOST:-sglang.k8s-test}"
sglang_base="http://${node_ip}:${ingress_port}"
tool_resp="$(curl -sf --max-time 120 "${sglang_base}/v1/chat/completions" \
  -H "Host: ${sglang_host}" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "QuantTrio/gemma-4-31B-it-AWQ",
    "messages": [{"role": "user", "content": "List tables for adventureworks using search_tables."}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "search_tables",
        "description": "Search MDL tables",
        "parameters": {
          "type": "object",
          "properties": {"query": {"type": "string"}},
          "required": ["query"]
        }
      }
    }],
    "tool_choice": "auto",
    "max_tokens": 128,
    "temperature": 0.1
  }' 2>/dev/null || true)"
if [ -z "${tool_resp}" ]; then
  warn "Tool-call probe HTTP failed (server loading?)"
else
  echo "${tool_resp}" | python3 -c "
import json, sys
r = json.load(sys.stdin)
msg = r['choices'][0]['message']
tc = msg.get('tool_calls')
content = msg.get('content') or ''
if tc:
    print('tool_calls:', json.dumps(tc, ensure_ascii=False))
    sys.exit(0)
if '<|tool_call>' in content:
    print('FAIL: raw gemma tool text in content:', content[:200])
    sys.exit(1)
print('WARN: no tool_calls and no <|tool_call> in content:', content[:200])
sys.exit(2)
" && ok "Structured tool_calls returned" || fail "Gemma tool output not parsed into tool_calls (check --tool-call-parser gemma4)"
fi

echo ""
echo "=== /v1/models (optional) ==="
node_ip="${NODE_IP:-192.168.150.200}"
ingress_port="${SGLANG_HTTP_PORT:-30000}"
sglang_host="${SGLANG_INGRESS_HOST:-sglang.k8s-test}"
models_url="http://${node_ip}:${ingress_port}/v1/models"
if curl -sf --max-time 5 -H "Host: ${sglang_host}" "${models_url}" >/dev/null; then
  ok "HTTP reachable at ${models_url} (Host: ${sglang_host})"
else
  warn "Could not reach ${models_url} with Host: ${sglang_host} (set NODE_IP /etc/hosts)"
fi

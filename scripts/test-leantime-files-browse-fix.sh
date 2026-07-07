#!/usr/bin/env bash
# TDD gate: Leantime /files/browse memory fix (isolated view() partial renders).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/charts/leantime"
VALUES="${ROOT_DIR}/helm/values/leantime.yaml"
PATCH_DIR="${CHART_DIR}/patches"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

[[ -d "${PATCH_DIR}/app/Domain/Menu/Templates/partials" ]] \
  || fail "Missing menu partial patches under ${PATCH_DIR}"

for f in \
  app/Domain/Menu/Templates/partials/projectSelector.blade.php \
  app/Domain/Menu/Templates/partials/projectGroup.blade.php \
  app/Domain/Menu/Templates/partials/noGroup.blade.php \
  app/Domain/Menu/Templates/partials/clientGroup.blade.php; do
  [[ -f "${PATCH_DIR}/${f}" ]] || fail "Missing patch file ${f}"
  grep -q "view('menu::partials" "${PATCH_DIR}/${f}" \
    || fail "${f} must use isolated view() renders (k8s-test files/browse fix)"
  grep -q "@include('menu::partials" "${PATCH_DIR}/${f}" \
    && fail "${f} must not use @include for menu partials (passes get_defined_vars)"
done

grep -q "modalPopUp=true' : ''" "${PATCH_DIR}/app/Domain/Files/Templates/showAll.blade.php" \
  || fail "showAll.blade.php must fix broken @if inside form action"

grep -q 'filesBrowseFix:' "${VALUES}" \
  || fail "helm/values/leantime.yaml must enable app.patch.filesBrowseFix"
grep -q 'enabled: true' "${VALUES}" \
  || fail "filesBrowseFix patch must be enabled in values"

helm template leantime-test "${CHART_DIR}" -f "${VALUES}" \
  --set-string 'app.url=https://leantime.k8s-test' >/tmp/leantime-patched.yaml \
  || fail "helm template failed"
grep -q 'leantime-test-app-patch' /tmp/leantime-patched.yaml \
  || fail "Rendered manifest must include app-patch ConfigMap"
grep -q 'projectSelector.blade.php' /tmp/leantime-patched.yaml \
  || fail "ConfigMap must embed projectSelector patch"
grep -q 'postStart' /tmp/leantime-patched.yaml \
  || fail "Deployment must clear compiled views after patch mount"
grep -q 'checksum/app-patch' /tmp/leantime-patched.yaml \
  || fail "Deployment must annotate checksum/app-patch (subPath ConfigMap mounts need rollout)"
grep -q 'projectSelectGroupOptions' "${PATCH_DIR}/app/Domain/Menu/Templates/partials/projectSelector.blade.php" \
  || fail "projectSelector patch must pass projectSelectGroupOptions to projectListFilter"
grep -q "view('menu::projectSelector'" "${PATCH_DIR}/app/Domain/Menu/Templates/headMenu.blade.php" \
  || fail "headMenu must use isolated view() for projectSelector (not @include)"
grep -q "@include('menu::partials.projectSelector'" "${PATCH_DIR}/app/Domain/Menu/Templates/projectSelector.blade.php" \
  && fail "projectSelector wrapper must not @include partials.projectSelector"
grep -q "view('menu::partials.projectSelector'" "${PATCH_DIR}/app/Domain/Menu/Templates/projectSelector.blade.php" \
  || fail "projectSelector wrapper must use isolated view() for partial"
grep -q "view('menu::headMenu')" "${PATCH_DIR}/app/Views/Templates/layouts/app.blade.php" \
  || fail "app layout must use isolated view() for headMenu (not @include)"
grep -q "view('menu::menu')" "${PATCH_DIR}/app/Views/Templates/layouts/app.blade.php" \
  || fail "app layout must use isolated view() for menu (not @include)"
grep -q "Frontcontroller::getActionName" "${PATCH_DIR}/app/Domain/Files/Templates/browse.blade.php" \
  && fail "browse.blade.php must not set \$action (triggers layout @include recursion)"
grep -q "view('auth::partials.loginInfo'" "${PATCH_DIR}/app/Domain/Menu/Templates/headMenu.blade.php" \
  || fail "headMenu must use isolated view() for loginInfo"

ok "Leantime files/browse patch config validation passed"

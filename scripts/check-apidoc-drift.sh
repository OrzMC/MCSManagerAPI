#!/usr/bin/env bash
# 官方 apidoc（MCSManager/Documentation）是否还包含我们实现的那几个端点。
#
# 官方**没有**机器可读的 OpenAPI 文件，`Sources/MCSMAPI/openapi.yml` 是按官方 markdown 手写的；
# 端点改名/下架时这里会报出来，提醒同步 spec（以及 app 侧的适配器）。
#
# 用法：./scripts/check-apidoc-drift.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${ROOT}/Sources/MCSMAPI/openapi.yml"
BASE="https://raw.githubusercontent.com/MCSManager/Documentation/master/apis"

docs="$(mktemp)"
trap 'rm -f "${docs}"' EXIT

for f in api_instance.md api_daemon.md; do
  curl -fsSL "${BASE}/${f}" >>"${docs}"
done

status=0
# 从 spec 里取出所有路径（/api/...），逐个在官方文档里找。
while IFS= read -r path; do
  if grep -Fq "${path}" "${docs}"; then
    echo "[ok] ${path}"
  else
    echo "[drift] 官方 apidoc 里找不到 ${path}（端点可能改名/下架，需同步 spec）" >&2
    status=1
  fi
done < <(grep -E '^  /api/' "${SPEC}" | sed -E 's/^  //; s/:$//')

exit "${status}"

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

# 官方文档里**确实没有**、但我们已确认在用的端点（面板内部路由）。
# 加进这里必须写清楚证据，别拿它掩盖真正的 drift。
undocumented_ok() {
  case "$1" in
    # 面板 `/api/auth` 是前端登录态的聚合接口，官方 apidoc 只写了 admin 那套。
    # 我们用它列"普通用户自己的实例"，实测 10.18.0 可正常返回（见 README「权限」节）。
    "/api/auth") return 0 ;;
    *) return 1 ;;
  esac
}

status=0
# 从 spec 里取出所有路径（/api/...），逐个在官方文档里找。
while IFS= read -r path; do
  if grep -Fq "${path}" "${docs}"; then
    echo "[ok] ${path}"
  elif undocumented_ok "${path}"; then
    echo "[skip] ${path}（官方文档未收录，已确认在用）"
  else
    echo "[drift] 官方 apidoc 里找不到 ${path}（端点可能改名/下架，需同步 spec）" >&2
    status=1
  fi
done < <(grep -E '^  /api/' "${SPEC}" | sed -E 's/^  //; s/:$//')

exit "${status}"

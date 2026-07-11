#!/usr/bin/env bash
#
# entrypoint.sh — multica-workspace 容器启动脚本
#
# 认证机制（已实测确认，参考 issue MEM-10 的排查）：
#   multica 的 daemon / CLI 通过 ~/.multica/config.json 里的 token 字段做认证。
#   daemon 并不会读取 MULTICA_TOKEN 这个环境变量——环境变量 MULTICA_TOKEN 只是
#   用来给 `multica login --token` 提供令牌值，由 login 把令牌「固化」写入
#   config.json 的 token 字段，之后 daemon 再去读 config.json 完成认证。
#   首启空卷时 config.json 还没有 token 字段，因此必须先 login 固化，否则
#   daemon 会直接报：not authenticated: run 'multica login' first。
#
# 本脚本在拉起 daemon 之前：
#   1) 检查 MULTICA_TOKEN 是否真的注入进来了；缺失就立刻以非零状态退出，
#      让人一眼看到「是令牌没配好」，而不是去翻 daemon 日志。
#   2) 在 login 之前先把 server_url / app_url 配置进 config.json——否则
#      multica login 会直接报 "No server configured. Run 'multica setup' first"，
#      导致登录失败。server_url 默认 https://api.multica.ai（可用环境变量
#      MULTICA_SERVER_URL 自托管覆盖），app_url 默认 https://multica.ai（可用
#      MULTICA_APP_URL 覆盖）。已持久化到卷里的配置（卷恢复场景）不会被覆盖，
#      除非显式传入对应的环境变量。判断依据是 ~/.multica/config.json 里是否
#      已显式存在对应键，而非 `config show` 的展示值（后者总会回退到默认值）。
#   3) 用 MULTICA_TOKEN 执行 multica login --token，把登录态固化进卷里的
#      config.json（daemon 实际读取的就是这里）。这一步若失败（令牌无效/过期/
#      不属于本工作区），立即以非零状态退出并给出排查提示，绝不带病启动 daemon。
#   4) 二次确认 multica auth status 通过（令牌确实被服务端认可），再前台拉起 daemon。
#
# 调试 / 进入容器（重要，便于手工排障）：
#   - 默认行为：exec 把 daemon 设为 PID 1，容器常驻运行。
#   - 命令覆盖：用 `docker run --rm <镜像> bash`（或 `docker compose run <svc> bash`）
#     即可覆盖默认命令，直接进入交互 shell，方便手工调试 / 执行一次性命令。
#   - 调试开关：设置环境变量 MULTICA_DEBUG_SHELL=1 启动容器，会跳过认证与 daemon，
#     直接给出交互 shell（即使没配 MULTICA_TOKEN 也能进，适合先排查环境）。
#   - 容器运行期间也可随时 `docker exec -it <容器名> bash` 进到里面（不经过本脚本）。
#
set -euo pipefail

echo "==> [multica-workspace] 启动前检查"

# 0) 调试开关：最优先。设了 MULTICA_DEBUG_SHELL 就直接进 shell，
#    跳过一切认证与 daemon（即使没配 MULTICA_TOKEN 也能进，方便先排查环境）。
if [ -n "${MULTICA_DEBUG_SHELL:-}" ]; then
  echo "==> MULTICA_DEBUG_SHELL 已设置，跳过认证与 daemon，进入调试 shell"
  exec "${SHELL:-/bin/bash}"
fi

# 1) 必须有 MULTICA_TOKEN，否则明确失败退出
if [ -z "${MULTICA_TOKEN:-}" ]; then
  echo "未设置 MULTICA_TOKEN，无法启动 daemon。"
  echo "   请在 .env 中配置 MULTICA_TOKEN（mul_... 用户 PAT 或 mcn_... Cloud Node PAT），"
  echo "   并通过 docker-compose 的 env_file 或 environment 注入到容器。"
  echo "   参考 README 的「快速开始」一节。"
  echo "   如需先进入容器排查，可设置 MULTICA_DEBUG_SHELL=1 启动，或用："
  echo "     docker compose run <svc> bash"
  exit 1
fi
echo "已检测到 MULTICA_TOKEN（长度 ${#MULTICA_TOKEN}）"

# 2) 先完成服务端配置，否则 multica login 会因 "No server configured" 失败。
#    判断某 key 是否已在持久化配置 config.json 中显式设置过：
#    已设置 -> 不覆盖（除非显式传入对应环境变量）；未设置 -> 写入环境变量值或官方默认。
MULTICA_SERVER_URL_DEFAULT="https://api.multica.ai"
MULTICA_APP_URL_DEFAULT="https://multica.ai"
CONFIG_JSON="${HOME:-/root}/.multica/config.json"

# 用法：config_has_key <key> <path> —— 不依赖 jq，用 python3 安全解析 JSON；
# 缺键或文件不存在都返回非 0。路径通过位置参数传入，避免依赖子进程环境变量。
config_has_key() {
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import json, sys
key, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
    sys.exit(0 if key in data else 1)
except Exception:
    sys.exit(1)
PY
}

# server_url
if [ -n "${MULTICA_SERVER_URL:-}" ]; then
  echo "==> 应用 server_url=${MULTICA_SERVER_URL}（来自 MULTICA_SERVER_URL）"
  multica config set server_url "${MULTICA_SERVER_URL}"
elif config_has_key server_url "${CONFIG_JSON}"; then
  echo "==> 沿用已持久化的 server_url（卷恢复，不覆盖）"
else
  echo "==> 应用默认 server_url=${MULTICA_SERVER_URL_DEFAULT}"
  multica config set server_url "${MULTICA_SERVER_URL_DEFAULT}"
fi

# app_url
if [ -n "${MULTICA_APP_URL:-}" ]; then
  echo "==> 应用 app_url=${MULTICA_APP_URL}（来自 MULTICA_APP_URL）"
  multica config set app_url "${MULTICA_APP_URL}"
elif config_has_key app_url "${CONFIG_JSON}"; then
  echo "==> 沿用已持久化的 app_url（卷恢复，不覆盖）"
else
  echo "==> 应用默认 app_url=${MULTICA_APP_URL_DEFAULT}"
  multica config set app_url "${MULTICA_APP_URL_DEFAULT}"
fi

# 3) 用令牌固化登录态到 config.json（daemon 实际读取的就是这里）
echo "==> 用 MULTICA_TOKEN 固化登录态（multica login --token）…"
if ! multica login --token "${MULTICA_TOKEN}" 2>/tmp/login.err; then
  echo "multica login --token 失败，daemon 将无法认证。常见原因："
  echo "   - MULTICA_TOKEN 不是有效令牌（例如仍是占位符 mcn_your_token_here，"
  echo "     或复制时带入了多余空格/引号/换行）"
  echo "   - 令牌已过期，或不属于该 Multica 工作区所在的服务端"
  echo "   - server_url / app_url 配置与服务端不匹配（自托管场景请确认 MULTICA_SERVER_URL）"
  echo "   请在容器内执行  printenv MULTICA_TOKEN  确认值已正确注入，"
  echo "   并到 Multica 平台重新生成一个有效令牌填入 .env。"
  echo "   服务端返回："
  sed 's/^/     /' /tmp/login.err
  exit 1
fi

# 4) 二次确认登录态确实生效（令牌被服务端认可）
if ! multica auth status >/dev/null 2>&1; then
  echo "登录态已写入但 multica auth status 仍不通过，请检查令牌有效性或网络连通性。"
  exit 1
fi
echo "已用 MULTICA_TOKEN 固化登录态（config.json 已写入 token）"

# 5) 决定最终启动什么：
#    - 默认（未覆盖命令，或仅带 --no-auto-update）-> 以前台方式拉起 daemon；
#    - 用户/compose 用 `run ... bash` 等覆盖了命令 -> 直接 exec 该命令（用于调试）。
if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--no-auto-update" ]; }; then
  echo "==> 以前台方式启动 multica daemon（设备名=${HOSTNAME}）"
  export MULTICA_DAEMON_DEVICE_NAME="${HOSTNAME}"
  exec multica daemon start --foreground --no-auto-update
else
  echo "==> 以覆盖命令启动：$*"
  exec "$@"
fi

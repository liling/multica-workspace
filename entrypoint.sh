#!/usr/bin/env bash
#
# entrypoint.sh — multica-workspace 容器启动脚本
#
# 关键事实（已在多场景实测验证）：
#   multica 的 daemon / CLI 只认 MULTICA_TOKEN 这个环境变量来做认证，
#   config.json 里的 token 字段、以及 multica login 持久化的登录态，
#   在“干净的空卷”环境下都无法让 daemon 通过认证。
#   只要进程持有 MULTICA_TOKEN，首次启动（空卷）即可直接认证，无需先 login。
#
# 早期实现里 daemon 启动前没有任何校验，一旦 MULTICA_TOKEN 没注入进去
#   （最常见原因是 docker-compose 的 .env 没放在 compose 文件同目录、或
#   .env 里的 KEY 带了 export / 引号导致解析失败），就会一直报：
#       not authenticated: run 'multica login' first
# 且容器本身不会立即退出，只能靠翻日志才发现。
#
# 本脚本在拉起 daemon 之前：
#   1) 检查 MULTICA_TOKEN 是否真的注入进来了；缺失就立刻以非零状态退出，
#      让人一眼看到“是令牌没配好”，而不是去翻 daemon 日志。
#   2) 若已配置令牌但尚无登录态，尝试 multica login --token 把令牌固化到
#      卷里的 config.json（幂等；失败也只是警告，因为 daemon 本身读 env 也能认证）。
#   3) 以前台 exec 方式拉起 multica daemon，使其成为 PID 1，正确接收 docker stop 等信号。
#
set -euo pipefail

echo "==> [multica-workspace] 启动前检查"

# 1) 必须有 MULTICA_TOKEN，否则明确失败退出（不让 daemon 静默报未认证）
if [ -z "${MULTICA_TOKEN:-}" ]; then
  echo "未设置 MULTICA_TOKEN，无法启动 daemon。"
  echo "   请在 .env 中配置 MULTICA_TOKEN（mcn_... Cloud Node PAT 或 mul_... 用户 PAT），"
  echo "   并通过 docker-compose 的 env_file 或 environment 注入到容器。"
  echo "   参考 README 的「快速开始」一节。"
  exit 1
fi
echo "已检测到 MULTICA_TOKEN（长度 ${#MULTICA_TOKEN}）"

# 2) 若尚未登录，则把令牌固化进卷里的 config.json（便于持久态、便于排查）
if ! multica auth status >/dev/null 2>&1; then
  echo "==> 尚未登录，尝试用 MULTICA_TOKEN 固化登录态…"
  if multica login --token "${MULTICA_TOKEN}" >/dev/null 2>&1; then
    echo "已用 MULTICA_TOKEN 登录（登录态已固化到卷）"
  else
    # 登录失败通常是令牌无效；但 daemon 本身会直接读取环境变量里的
    # MULTICA_TOKEN 来认证，所以这里只警告、不中止。
    echo "multica login --token 失败（令牌可能无效或已过期），"
    echo "   daemon 将直接尝试用环境变量 MULTICA_TOKEN 认证。"
  fi
else
  echo "已有登录态"
fi

# 3) 前台拉起 daemon：设备名取容器自身 HOSTNAME（compose 里的 hostname），
#    默认关闭 CLI 自更新，让镜像版本保持稳定、避免运行期联网拉取。
echo "==> 以前台方式启动 multica daemon（设备名=${HOSTNAME}）"
export MULTICA_DAEMON_DEVICE_NAME="${HOSTNAME}"
exec multica daemon start --foreground --no-auto-update "$@"

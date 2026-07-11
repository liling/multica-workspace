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
#   2) 用 MULTICA_TOKEN 执行 multica login --token，把登录态固化进卷里的
#      config.json（daemon 实际读取的就是这里）。这一步若失败（令牌无效/过期/
#      不属于本工作区），立即以非零状态退出并给出排查提示，绝不带病启动 daemon。
#   3) 二次确认 multica auth status 通过（令牌确实被服务端认可），再前台拉起 daemon。
#
set -euo pipefail

echo "==> [multica-workspace] 启动前检查"

# 1) 必须有 MULTICA_TOKEN，否则明确失败退出
if [ -z "${MULTICA_TOKEN:-}" ]; then
  echo "未设置 MULTICA_TOKEN，无法启动 daemon。"
  echo "   请在 .env 中配置 MULTICA_TOKEN（mul_... 用户 PAT 或 mcn_... Cloud Node PAT），"
  echo "   并通过 docker-compose 的 env_file 或 environment 注入到容器。"
  echo "   参考 README 的「快速开始」一节。"
  exit 1
fi
echo "已检测到 MULTICA_TOKEN（长度 ${#MULTICA_TOKEN}）"

# 2) 用令牌固化登录态到 config.json（daemon 实际读取的就是这里）
echo "==> 用 MULTICA_TOKEN 固化登录态（multica login --token）…"
if ! multica login --token "${MULTICA_TOKEN}" 2>/tmp/login.err; then
  echo "multica login --token 失败，daemon 将无法认证。常见原因："
  echo "   - MULTICA_TOKEN 不是有效令牌（例如仍是占位符 mcn_your_token_here，"
  echo "     或复制时带入了多余空格/引号/换行）"
  echo "   - 令牌已过期，或不属于该 Multica 工作区所在的服务端"
  echo "   请在容器内执行  printenv MULTICA_TOKEN  确认值已正确注入，"
  echo "   并到 Multica 平台重新生成一个有效令牌填入 .env。"
  echo "   服务端返回："
  sed 's/^/     /' /tmp/login.err
  exit 1
fi

# 3) 二次确认登录态确实生效（令牌被服务端认可）
if ! multica auth status >/dev/null 2>&1; then
  echo "登录态已写入但 multica auth status 仍不通过，请检查令牌有效性或网络连通性。"
  exit 1
fi
echo "已用 MULTICA_TOKEN 固化登录态（config.json 已写入 token）"

# 4) 前台拉起 daemon：设备名取容器自身 HOSTNAME（compose 里的 hostname），
#    默认关闭 CLI 自更新，让镜像版本保持稳定、避免运行期联网拉取。
echo "==> 以前台方式启动 multica daemon（设备名=${HOSTNAME}）"
export MULTICA_DAEMON_DEVICE_NAME="${HOSTNAME}"
exec multica daemon start --foreground --no-auto-update "$@"

# syntax=docker/dockerfile:1
#
# 基于 Debian trixie 官方镜像，安装 opencode、hermes、multica 的最新版本，
# 以及 gstack（Garry Tan 的 Claude Code 技能集）所需运行环境，
# 并在容器启动时拉起 multica daemon（前台运行）。
#
# 另外补充（见 issue MEM-12）：
#   - 预装 openssh-client，便于容器内通过 SSH 拉取仓库 / 跑 git+ssh。
#   - 预建 /root/.ssh 目录（权限 700）用于存放 SSH 密钥；该目录应通过卷持久化
#     （见 README「数据卷」一节），避免容器重建后密钥丢失。
#   - 容器默认工作目录（WORKDIR）设为 /workspace，方便 shell / 调试命令落地。
#     （注意：multica daemon 的任务工作区仍在 ~/multica_workspaces，二者互不影响。）
#
# 安装方式（均经实测，x86_64 / arm64 glibc Linux 下可跑通）：
#   - opencode : 官方脚本 https://opencode.ai/install
#                -> 二进制落在 $HOME/.opencode/bin/opencode
#   - hermes   : 官方脚本 https://hermes-agent.nousresearch.com/install.sh
#                -> root 下命令落在 /usr/local/bin/hermes，
#                   代码在 /usr/local/lib/hermes-agent，数据在 $HERMES_HOME(/root/.hermes)
#   - multica  : 官方脚本 https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh
#                -> root 下命令落在 /usr/local/bin/multica（已位于默认 PATH）
#   - gstack   : scripts/gstack-install.sh（本仓库随附），克隆 gstack 仓库并 build
#                其 browse 二进制、安装 Playwright Chromium、注册 55 个技能到
#                ~/.claude/skills/。详见该脚本头注释。
#
# 说明：
#   - opencode / hermes / multica 三个安装器均拉取“构建当时”的最新版本，
#     因此每次 `docker build` 会得到当时最新的三者（镜像本身不锁定具体版本号）。
#     若需锁定版本，可在 opencode 安装器后加 `--version <ver>`、
#     在 hermes 安装器后加 `--commit <sha>`、在 multica 安装器后加 `--version <ver>`
#     （见各自官方文档）。
#   - gstack 由随附脚本安装（Bun、Playwright Chromium、55 个技能等），版本随其仓库 HEAD。
#   - opencode 安装器默认只修改 ~/.bashrc 的 PATH；容器内的非交互 shell
#     并不读取 .bashrc，因此这里用 ENV PATH 显式注入，确保
#     `docker run --rm <img> opencode` / `hermes` 直接可用。
#   - multica 安装器默认将二进制放入 /usr/local/bin（root 可写，已位于默认 PATH），
#     故无需额外修改 PATH。
#   - 镜像以 root 用户运行（与各安装器的默认布局一致）。
#   - 认证说明（重要）：multica 的 daemon / CLI 只认 MULTICA_TOKEN 这个
#     环境变量做认证；config.json 里的 token 字段、multica login 持久化的
#     登录态，在“空卷”环境下都无法让 daemon 通过认证。只要容器进程持有
#     MULTICA_TOKEN，首次启动即可直接认证，无需先 login。
#     容器用 entrypoint.sh 在拉起 daemon 前校验 MULTICA_TOKEN，缺失则明确
#     非零退出（便于排查），不会静默一直报 “not authenticated”。

FROM debian:trixie

# 避免 apt 在构建期弹出交互式配置界面
ENV DEBIAN_FRONTEND=noninteractive

# 基础依赖：
#   bash          安装脚本以 #!/usr/bin/env bash 运行
#   git/curl/tar/xz-utils/ca-certificates  opencode/hermes/multica 三个安装器运行所需
#   ripgrep/ffmpeg  hermes 的文件检索与 TTS 语音功能依赖，预装以避免构建期临时 apt
#   nodejs        gstack 的 build / Playwright 运行需要全局 node
#                （hermes 自带 node 仅在其 venv 内，不在全局 PATH）
#   openssh-client  便于容器内通过 SSH 拉取仓库 / 跑 git+ssh（issue MEM-12）
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        git \
        curl \
        ca-certificates \
        tar \
        xz-utils \
        ripgrep \
        ffmpeg \
        nodejs \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# 安装 opencode（官方脚本，非交互，自动选取最新版与匹配 CPU 的构建；
# --no-modify-path 避免改动 /root/.bashrc，PATH 由下方 ENV 统一管理）
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path

# 安装 hermes（--skip-setup 跳过交互式初始化向导；
# 它会自行用 uv 拉取 Python 3.11 / Node 22 并安装依赖）
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup

# 安装 multica CLI（官方脚本，默认仅安装 CLI，不附带 self-host server；
# 二进制落在 /usr/local/bin/multica，已位于默认 PATH）
RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

# 让两个命令在任意 shell 下都可用，并固定 hermes 的数据目录
ENV HERMES_HOME=/root/.hermes \
    PATH="/root/.opencode/bin:/usr/local/bin:${PATH}"

# 安装 gstack 运行环境（Bun、Playwright Chromium、55 个技能等）。
# 脚本随仓库提供（scripts/gstack-install.sh）；非交互、幂等。
# 默认把 gstack 注册为 Claude Code 风格技能（短名 /qa、/review…）到
# ~/.claude/skills/。改用命名空间 /gstack-qa 可在脚本内设置 SETUP_PREFIX=1。
COPY scripts/gstack-install.sh /opt/gstack-install.sh
RUN bash /opt/gstack-install.sh

# 预建 SSH 密钥目录与容器工作目录（issue MEM-12）：
#   - /root/.ssh 用于存放 SSH 密钥，权限收紧为 700；应通过卷持久化，
#     否则容器重建后密钥会丢失（见 README「数据卷」一节）。
#   - /workspace 作为容器默认工作目录（WORKDIR），方便 shell / 调试命令落地。
RUN mkdir -p /root/.ssh /workspace \
    && chmod 700 /root/.ssh

# 构建期自检：确保三个二进制都真的可用（构建失败即暴露安装问题）
RUN opencode --version \
    && hermes --version \
    && multica version

# 启动脚本：在拉起 daemon 前校验/固化 MULTICA_TOKEN 认证，未配置则明确失败退出，
# 避免容器一直静默报 “not authenticated”。详见 entrypoint.sh 头部注释。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 容器默认工作目录设为 /workspace（任务/调试命令的落地目录，便于使用）。
WORKDIR /workspace

# 容器启动时：以前台方式拉起 multica daemon。
# entrypoint.sh 负责：
#   - 校验 MULTICA_TOKEN 是否已注入（缺失则直接非零退出，便于排查）
#   - 必要时用 MULTICA_TOKEN 固化登录态
#   - 以容器自身 HOSTNAME 作为 daemon 设备名
#   - exec 让 daemon 成为 PID 1，确保能正确接收 docker stop 等信号
# opencode / hermes / gstack 环境同样在镜像中可用。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--no-auto-update"]

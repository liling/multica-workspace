# syntax=docker/dockerfile:1
#
# 基于 Debian trixie 官方镜像，安装 opencode、hermes 的最新版本，
# 以及 gstack（Garry Tan 的 Claude Code 技能集）所需运行环境。
#
# 安装方式（均经实测，x86_64 glibc Linux 下可跑通）：
#   - opencode : 官方脚本 https://opencode.ai/install
#                -> 二进制落在 $HOME/.opencode/bin/opencode
#   - hermes   : 官方脚本 https://hermes-agent.nousresearch.com/install.sh
#                -> root 下命令落在 /usr/local/bin/hermes，
#                   代码在 /usr/local/lib/hermes-agent，数据在 $HERMES_HOME(/root/.hermes)
#   - gstack   : scripts/gstack-install.sh（本仓库随附），克隆 gstack 仓库并 build
#                其 browse 二进制、安装 Playwright Chromium、注册 55 个技能到
#                ~/.claude/skills/。详见该脚本头注释。
#
# 说明：
#   - 两个安装器均拉取“构建当时”的最新版本，因此每次 `docker build`
#     会得到当时最新的 opencode / hermes（镜像本身不锁定具体版本号）。
#     若需锁定版本，可在 opencode 安装器后加 `--version <ver>`、
#     在 hermes 安装器后加 `--commit <sha>`（见各自官方文档）。
#   - opencode 安装器默认只修改 ~/.bashrc 的 PATH；容器内的非交互 shell
#     并不读取 .bashrc，因此这里用 ENV PATH 显式注入，确保
#     `docker run --rm <img> opencode` / `hermes` 直接可用。
#   - 镜像以 root 用户运行（与两个安装器的默认布局一致）。

FROM debian:trixie

# 避免 apt 在构建期弹出交互式配置界面
ENV DEBIAN_FRONTEND=noninteractive

# 基础依赖：
#   bash          安装脚本以 #!/usr/bin/env bash 运行
#   git/curl/tar/xz-utils/ca-certificates  两个安装器运行所需
#   ripgrep/ffmpeg  hermes 的文件检索与 TTS 语音功能依赖，预装以避免构建期临时 apt
#   nodejs        gstack 的 build / Playwright 运行需要全局 node
#                （hermes 自带 node 仅在其 venv 内，不在全局 PATH）
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
    && rm -rf /var/lib/apt/lists/*

# 安装 opencode（官方脚本，非交互，自动选取最新版与匹配 CPU 的构建；
# --no-modify-path 避免改动 /root/.bashrc，PATH 由下方 ENV 统一管理）
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path

# 安装 hermes（--skip-setup 跳过交互式初始化向导；
# 它会自行用 uv 拉取 Python 3.11 / Node 22 并安装依赖）
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup

# 让两个命令在任意 shell 下都可用，并固定 hermes 的数据目录
ENV HERMES_HOME=/root/.hermes \
    PATH="/root/.opencode/bin:/usr/local/bin:${PATH}"

# 安装 gstack 运行环境（Bun、Playwright Chromium、55 个技能等）。
# 脚本随仓库提供（scripts/gstack-install.sh）；非交互、幂等。
# 默认把 gstack 注册为 Claude Code 风格技能（短名 /qa、/review…）到
# ~/.claude/skills/。改用命名空间 /gstack-qa 可在脚本内设置 SETUP_PREFIX=1。
COPY scripts/gstack-install.sh /opt/gstack-install.sh
RUN bash /opt/gstack-install.sh

# 构建期自检：确保两个二进制都真的可用（构建失败即暴露安装问题）
RUN opencode --version \
    && hermes --version

# 默认进入 bash；opencode / hermes / gstack 环境均可用
CMD ["/bin/bash"]

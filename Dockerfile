# syntax=docker/dockerfile:1
#
# 基于 Debian trixie 官方镜像，安装 pi 与由构建参数指定版本的 multica，
# 并在容器启动时拉起 multica daemon（前台运行）。
#
# 关于 pi（取代 opencode，参考 issue MEM-15）：
#   opencode 在容器里运行时占用内存较高，容易触发 OOM；改用 Mario Zechner
#   （earendil-works）的 pi 作为更轻量的终端编程 agent 替代。pi 是 Node/npm 包，
#   通过 `npm install -g @earendil-works/pi-coding-agent` 安装，命令落在
#   npm 全局 bin 目录（root 下为 /usr/local/bin/pi），配置/会话/凭据等
#   数据落在 ~/.pi/agent/（建议通过卷持久化）。
#
# 另外补充（见 issue MEM-12）：
#   - 预装 openssh-client，便于容器内通过 SSH 拉取仓库 / 跑 git+ssh。
#   - 预建 /root/.ssh 目录（权限 700）用于存放 SSH 密钥；该目录应通过卷持久化
#     （见 README「数据卷」一节），避免容器重建后密钥丢失。
#   - 容器默认工作目录（WORKDIR）设为 /root/multica_workspaces，与 multica daemon
#     的任务工作区基目录一致，方便 shell / 调试命令直接落在任务代码所在区域。
#   - 预装 GitHub CLI（gh），便于在容器内直接操作 GitHub（PR / issue / workflow 等）。
#
# 安装方式（均经实测，x86_64 / arm64 glibc Linux 下可跑通）：
#   - pi       : `npm install -g @earendil-works/pi-coding-agent`
#                -> 二进制落在 npm 全局 bin 目录（root 下 /usr/local/bin/pi），
#                   配置 / 凭据 / 会话在 ~/.pi/agent/
#   - multica  : 官方脚本 https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh
#                -> root 下命令落在 /usr/local/bin/multica（已位于默认 PATH）
#   - gh      : GitHub 官方 apt 仓库 https://cli.github.com/packages（GitHub CLI）
#                -> root 下命令落在 /usr/local/bin/gh，已位于默认 PATH
#
# 说明：
#   - CI 从 upstream 最新稳定 release 解析 MULTICA_VERSION，作为 build arg 传入；
#     本地构建须显式传入同一参数。版本变化才会使 multica 安装层失效。
#     pi 等未 pin 的组件仍可能命中 BuildKit 缓存，并非每次构建都会更新。
#   - multica 安装器与 npm 全局安装默认将二进制放入 /usr/local/bin（root 可写，
#     已位于默认 PATH），故无需额外修改 PATH。
#   - 镜像以 root 用户运行（与各安装器的默认布局一致）。
#   - supervisor 优先检查持久化认证；认证失效时才尝试用 MULTICA_TOKEN 登录。

FROM debian:trixie

# 避免 apt 在构建期弹出交互式配置界面
ENV DEBIAN_FRONTEND=noninteractive

# 基础依赖：
#   bash          安装脚本以 #!/usr/bin/env bash 运行
#   git/curl/tar/xz-utils/ca-certificates  pi / multica 两个安装器运行所需
#   ripgrep       pi 的 find 工具与 tab 自动补全依赖 rg（与 fd-find 同一思路：预装避免
#                 空卷/离线环境首次启动时从 GitHub 下载，确保 pi 启动时 ensureTool 一步到位）。
#   fd-find        pi 的 find 工具与 tab 自动补全依赖 fd（issue MEM-23：首次启动报
#                  "fd not found"）。Debian 包名是 fd-find，但为避免与 fdclone 冲突，
#                  装出的命令叫 fdfind 而非 fd；pi 自动识别 fdfind（tools-manager 的
#                  systemBinaryNames 含 fdfind），故无需额外建 fd 软链。预装后首次启动
#                  不再从 GitHub 下载 fd，空卷/离线环境下 pi 的 find 工具也可直接用。
#   nodejs        pi 要求 Node >= 22.19.0（package.json engines 字段，是「下限」
#                 而非上限，故 Node 24 同样满足、官方支持）。Debian trixie 默认 nodejs
#                 较旧（20.x），这里从 NodeSource 的 node_24.x 通道装 Node 24，替换默认
#                 的 nodejs / npm。pi 作为 npm 包在 Node 24 上正常运行。
#   openssh-client  便于容器内通过 SSH 拉取仓库 / 跑 git+ssh（issue MEM-12）
#   vim           容器内编辑文本文件，便于调试 / 临时改动（issue MEM-24）
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        git \
        curl \
        ca-certificates \
        tar \
        xz-utils \
        ripgrep \
        fd-find \
        nodejs \
        openssh-client \
        vim \
        python3 \
        jq \
        build-essential \
        tini \
        chromium \
        docker-cli \
    && rm -rf /var/lib/apt/lists/* \
    && node --version \
    && npm --version

# 安装 pi（取代 opencode，见 issue MEM-15）
# pi 是 Node 包，用 `npm install -g` 全局安装即可：
#   - `--ignore-scripts` 跳过可选的 postinstall 脚本（官方安装说明建议）；
#   - 二进制落在 npm 全局 bin 目录（root 下 /usr/local/bin/pi），已位于默认 PATH；
#   - 配置 / 凭据 / 会话等数据落在 ~/.pi/agent/，建议通过卷持久化（见 README）。
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN npm install -g @openai/codex chrome-devtools-mcp && npm install -g --allow-scripts=pnpm pnpm

# upstream install.sh 不支持 --version：直接取指定 release 的官方 CLI 归档。
# ARG 紧邻安装层；版本变化时 cache key 改变，未变化时保留其它层缓存。
# 用 RUN 内的版本比对阻止下载到错误二进制后推送镜像。
ARG MULTICA_VERSION
RUN set -eu; \
    : "${MULTICA_VERSION:?must pass MULTICA_VERSION (e.g. v0.6.1)}"; \
    case "$MULTICA_VERSION" in \
        v[0-9]*.[0-9]*.[0-9]*) ;; \
        *) echo "Invalid MULTICA_VERSION: $MULTICA_VERSION" >&2; exit 1 ;; \
    esac; \
    case "$(dpkg --print-architecture)" in \
        amd64|arm64) MULTICA_ARCH="$(dpkg --print-architecture)" ;; \
        *) echo "Unsupported Multica architecture" >&2; exit 1 ;; \
    esac; \
    version="${MULTICA_VERSION#v}"; \
    echo "Installing Multica CLI target: ${MULTICA_VERSION} (linux/${MULTICA_ARCH})"; \
    curl -fsSL "https://github.com/multica-ai/multica/releases/download/${MULTICA_VERSION}/multica-cli-${version}-linux-${MULTICA_ARCH}.tar.gz" -o /tmp/multica.tar.gz; \
    tar -xzf /tmp/multica.tar.gz -C /usr/local/bin multica; \
    chmod 0755 /usr/local/bin/multica; \
    rm /tmp/multica.tar.gz; \
    actual="$(multica version)"; \
    echo "Multica CLI target: ${MULTICA_VERSION}; installed: ${actual}"; \
    [ "$(printf '%s\n' "$actual" | awk 'NR==1 {print $1 " " $2}')" = "multica ${version}" ]

# 安装 GitHub CLI（gh）——官方 apt 仓库（cli.github.com）。
# 便于在容器内直接操作 GitHub（PR / issue / workflow 等）。
# 需要 gnupg 处理仓库签名密钥；gh 二进制落在 /usr/local/bin/gh，已位于默认 PATH。
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# 自检阶段前所有 CLI 均位于默认 PATH。

# 预建 SSH 密钥目录与容器工作目录（issue MEM-12）：
#   - /root/.ssh 用于存放 SSH 密钥，权限收紧为 700；应通过卷持久化，
#     否则容器重建后密钥会丢失（见 README「数据卷」一节）。
#   - /root/multica_workspaces 作为容器默认工作目录（WORKDIR），与 daemon 任务
#     工作区基目录一致（运行期由 agent-workspaces 卷覆盖）。
RUN mkdir -p /root/.ssh /root/multica_workspaces \
    && chmod 700 /root/.ssh

RUN set -eux; \
    pi --version; \
    codex --version; \
    multica version; \
    gh --version; \
    docker --version; chromium --version; python3 --version; jq --version; pnpm --version; \
    npx --no-install chrome-devtools-mcp --help >/dev/null; \
    echo "All workstation tools are available."

# 启动脚本：在拉起 daemon 前校验/固化 MULTICA_TOKEN 认证，未配置则明确失败退出，
# 避免容器一直静默报 “not authenticated”。详见 entrypoint.sh 头部注释。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

# 容器默认工作目录设为 /root/multica_workspaces（与 daemon 任务工作区基目录一致，
# 方便 docker exec 进容器后直接落在任务代码所在区域）。
WORKDIR /root/multica_workspaces

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["--no-auto-update"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]

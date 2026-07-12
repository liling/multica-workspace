# syntax=docker/dockerfile:1
#
# 基于 Debian trixie 官方镜像，安装 pi、hermes、multica 的最新版本，
# 以及 pi 扩展形式的 gstack / subagents 适配层，
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
#   - 容器默认工作目录（WORKDIR）设为 /workspace，方便 shell / 调试命令落地。
#     （注意：multica daemon 的任务工作区仍在 ~/multica_workspaces，二者互不影响。）
#   - 预装 GitHub CLI（gh），便于在容器内直接操作 GitHub（PR / issue / workflow 等）。
#
# 安装方式（均经实测，x86_64 / arm64 glibc Linux 下可跑通）：
#   - pi       : `npm install -g @earendil-works/pi-coding-agent`
#                -> 二进制落在 npm 全局 bin 目录（root 下 /usr/local/bin/pi），
#                   配置 / 凭据 / 会话在 ~/.pi/agent/
#   - hermes   : 官方脚本 https://hermes-agent.nousresearch.com/install.sh
#                -> root 下命令落在 /usr/local/bin/hermes，
#                   代码在 /usr/local/lib/hermes-agent，数据在 $HERMES_HOME(/root/.hermes)
#                   构建时加 --skip-setup --skip-browser（issue MEM-16），
#                   跳过 setup 向导与 Playwright/Chromium 下载以省流量。
#   - multica  : 官方脚本 https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh
#                -> root 下命令落在 /usr/local/bin/multica（已位于默认 PATH）
#   - pi 扩展 : 通过 pi CLI 安装 npm 包形式的 gstack / subagents 适配层（见 issue MEM-18）：
#                pi install npm:pi-subagents  -> pi 原生子智能体委托扩展
#                pi install npm:pi-gstack      -> 把 Garry Tan 的 gstack 技能与工作流
#                                                以 pi 扩展形式适配进 pi（运行时按需
#                                                拉取上游 gstack 仓库，并注册为
#                                                /gstack-* 命名空间技能）。
#                两包都落到 ~/.pi/agent/ 下（npm 包目录 + settings.json 条目），
#                镜像默认通过卷持久化 /root/.pi/agent（见 README）。
#   - gh      : GitHub 官方 apt 仓库 https://cli.github.com/packages（GitHub CLI）
#                -> root 下命令落在 /usr/local/bin/gh，已位于默认 PATH
#
# 说明：
#   - pi / hermes / multica / pi 扩展四个安装器均拉取“构建当时”的最新版本，
#     因此每次 `docker build` 会得到当时最新的全部组件（镜像本身不锁定具体版本号）。
#     若需锁定版本，可在 pi 的 npm install 上加 `@<ver>`、在 hermes 安装器后加
#     `--commit <sha>`、在 multica 安装器后加 `--version <ver>`、在 pi 扩展上
#     加 `@<ver>`（见各自官方文档）。
#   - 相对于原先的 scripts/gstack-install.sh 方案（克隆 gstack、安装 Bun、
#     拉 Playwright Chromium、把技能注册到 ~/.claude/skills/），现在改走
#     pi 扩展后不再需要 Bun / Playwright / 任何额外系统层依赖，更轻量且与
#     pi 生态对齐。pi-gstack 在首次 `/gstack-build` 时按需编译 gstack
#     的 browse 二进制及安装 Playwright Chromium（非镜像构建期）。
#   - hermes 安装器默认只修改 ~/.bashrc 的 PATH；容器内的非交互 shell
#     并不读取 .bashrc，因此这里用 ENV PATH 显式注入，确保
#     `docker run --rm <img> hermes` / `multica` 直接可用。
#   - multica 安装器与 npm 全局安装默认将二进制放入 /usr/local/bin（root 可写，
#     已位于默认 PATH），故无需额外修改 PATH。
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
#   git/curl/tar/xz-utils/ca-certificates  pi/hermes/multica 三个安装器运行所需
#   ripgrep/ffmpeg  hermes 的文件检索与 TTS 语音功能依赖，预装以避免构建期临时 apt
#   nodejs        pi 要求 Node >= 22.19.0（见其 package.json engines 字段），
#                 而 Debian trixie 默认 nodejs 是 20.x。这里从 NodeSource 装
#                 Node 22 LTS，替换默认的 nodejs / npm，确保 pi 能跑起来。
#                 pi 扩展（pi-subagents / pi-gstack）作为 npm 包安装，pi 装好即可用。
#   openssh-client  便于容器内通过 SSH 拉取仓库 / 跑 git+ssh（issue MEM-12）
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
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
        ffmpeg \
        nodejs \
        openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && node --version \
    && npm --version

# 安装 pi（取代 opencode，见 issue MEM-15）
# pi 是 Node 包，用 `npm install -g` 全局安装即可：
#   - `--ignore-scripts` 跳过可选的 postinstall 脚本（官方安装说明建议）；
#   - 二进制落在 npm 全局 bin 目录（root 下 /usr/local/bin/pi），已位于默认 PATH；
#   - 配置 / 凭据 / 会话等数据落在 ~/.pi/agent/，建议通过卷持久化（见 README）。
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# 安装 pi 扩展（gstack / subagents 适配层，见 issue MEM-18）：
#   此前 Dockerfile 通过 scripts/gstack-install.sh 克隆 gstack 仓库、装 Bun / Playwright
#   Chromium 并把技能注册到 ~/.claude/skills/，镜像很大且与 pi 生态脱节。这里改为直接
#   通过 pi 把这两个 npm 扩展装进 ~/.pi/agent/，省掉 Bun / Playwright 等系统依赖：
#     - pi install npm:pi-subagents  提供 pi 原生子智能体委托（reviewer / scout / oracle 等）
#     - pi install npm:pi-gstack      把 Garry Tan 的 gstack 技能与工作流以 pi 扩展形式
#                                       适配进 pi；首次 /gstack-build 时按需拉上游仓库、
#                                       编译 browse 二进制、装 Playwright Chromium。
#   每条 pi install 只 write settings.json + 下载一个 npm 包到 ~/.pi/agent/npm/，
#   不引入任何 postinstall 之外的额外系统依赖。失败立即暴露（构建失败即报错）。
RUN pi install npm:pi-subagents \
    && pi install npm:pi-gstack

# 安装 hermes（issue MEM-16）：
#   --skip-setup   跳过交互式初始化向导（容器内无 tty，原本也会被安装器自动跳过；
#                   这里显式带上更清晰，也防止未来安装器探测逻辑变化）
#   --skip-browser 跳过 Playwright/Chromium 下载（节省构建期网络流量与磁盘空间；
#                   代价是镜像里 hermes 的 browser tools 不可用，如需可在运行期手动：
#                   cd $INSTALL_DIR && npx playwright install chromium）
# 安装器自行用 uv 拉取 Python 3.11 / Node 22 并安装依赖。
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --skip-browser

# 安装 multica CLI（官方脚本，默认仅安装 CLI，不附带 self-host server；
# 二进制落在 /usr/local/bin/multica，已位于默认 PATH）
RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

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

# 让 hermes 数据目录在任意 shell 下都可被定位（pi / multica / gh 已在默认 PATH 上）
ENV HERMES_HOME=/root/.hermes

# 预建 SSH 密钥目录与容器工作目录（issue MEM-12）：
#   - /root/.ssh 用于存放 SSH 密钥，权限收紧为 700；应通过卷持久化，
#     否则容器重建后密钥会丢失（见 README「数据卷」一节）。
#   - /workspace 作为容器默认工作目录（WORKDIR），方便 shell / 调试命令落地。
# pi 扩展（pi-subagents / pi-gstack）数据落在 ~/.pi/agent/，由上面卷映射持久化。
RUN mkdir -p /root/.ssh /workspace \
    && chmod 700 /root/.ssh

# 构建期自检：确保各二进制都真的可用（构建失败即暴露安装问题）。
# pi 扩展不强制自检：它们在首次 `pi` 启动时才加载，构建期未启动 pi 会话时
# 静默运行也无意义；如果扩展有问题会在第一次使用时立刻报错。
RUN pi --version \
    && hermes --version \
    && multica version \
    && gh --version

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
# pi / hermes / pi 扩展（pi-subagents、pi-gstack）环境同样在镜像中可用。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--no-auto-update"]

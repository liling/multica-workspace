# syntax=docker/dockerfile:1
#
# On-prem workspace image.
# GitHub-only artifacts are already present in BOOTSTRAP_IMAGE. Everything in
# this file must be buildable from China-friendly mirrors so the server does
# not need direct access to github.com.

ARG BOOTSTRAP_IMAGE=ghcr.nju.edu.cn/liling/multica-workspace-bootstrap:latest
FROM ${BOOTSTRAP_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Prefer TUNA wherever it provides the required upstream. npm has no equivalent
# TUNA registry mirror, so npmmirror is the explicit exception.
ARG DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
ARG DEBIAN_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian-security
ARG NODE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release
ARG NPM_REGISTRY=https://registry.npmmirror.com

ARG PI_VERSION=1.4.0
ARG CODEX_VERSION=0.166.0
ARG CHROME_DEVTOOLS_MCP_VERSION=1.12.0
ARG PNPM_VERSION=12.15.0

# Switch Debian package sources before the first package installation performed
# on the server. Debian trixie uses deb822 sources by default.
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i \
        -e "s|https\?://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https\?://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
      sed -i \
        -e "s|https\?://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https\?://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list; \
    fi

# Development, browser and network troubleshooting tools.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        git \
        curl \
        wget \
        ca-certificates \
        tar \
        xz-utils \
        ripgrep \
        fd-find \
        openssh-client \
        vim \
        python3 \
        jq \
        build-essential \
        tini \
        chromium \
        docker-cli \
        sudo \
        gh \
        dnsutils \
        iputils-ping \
        iproute2 \
        netcat-openbsd \
        traceroute \
    && rm -rf /var/lib/apt/lists/*

# Install the latest Node 24 patch release from TUNA for the current architecture.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "Unsupported Node architecture: $(dpkg --print-architecture)" >&2; exit 2 ;; \
    esac; \
    NODE_BASE="${NODE_MIRROR%/}/latest-v24.x"; \
    NODE_FILE="$(curl -fsSL "$NODE_BASE/SHASUMS256.txt" \
      | awk -v arch="$NODE_ARCH" '$2 ~ ("node-v[0-9.]+-linux-" arch "\\.tar\\.xz$") {print $2; exit}')"; \
    test -n "$NODE_FILE"; \
    echo "Installing Node from $NODE_BASE/$NODE_FILE"; \
    curl -fsSL "$NODE_BASE/$NODE_FILE" -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm /tmp/node.tar.xz; \
    node --version; \
    npm --version

# Install npm-distributed workstation tools from the China-friendly registry.
RUN set -eux; \
    npm config set registry "$NPM_REGISTRY"; \
    npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"; \
    npm install -g "@openai/codex@${CODEX_VERSION}" "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}"; \
    npm install -g --allow-scripts=pnpm "pnpm@${PNPM_VERSION}"

RUN groupadd --gid 1000 multica \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/multica --shell /bin/bash multica \
    && install -d -o 1000 -g 1000 -m 0700 /home/multica/.ssh \
    && install -d -o 1000 -g 1000 -m 0755 /home/multica/.multica /home/multica/.pi/agent /home/multica/.codex /home/multica/.config/gh /home/multica/multica_workspaces \
    && install -d -o 1000 -g 1000 -m 0755 /run/multica-workspace \
    && printf '%s\n' 'multica ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/multica \
    && chmod 0440 /etc/sudoers.d/multica \
    && visudo -cf /etc/sudoers.d/multica

# Validate the complete runtime contract. Multica comes from the bootstrap image;
# every other tool above comes from TUNA/npmmirror-backed server-side installation.
RUN set -eux; \
    su -s /bin/bash multica -c 'set -euo pipefail; id -u; id -g; test "$HOME" = /home/multica; \
      pi --version; codex --version; multica version; gh --version; docker --version; \
      chromium --version; chrome-devtools-mcp --version; python3 --version; jq --version; pnpm --version; \
      command -v host; command -v dig; command -v nslookup; command -v ping; command -v wget; \
      command -v ip; command -v ss; command -v nc; command -v traceroute; \
      sudo -n id -u | grep -qx 0; test "$(id -u)" = 1000'; \
    test "$(stat -c %a:%u:%g /home/multica/.ssh)" = 700:1000:1000; \
    test "$(stat -c %a:%u:%g /run/multica-workspace)" = 755:1000:1000

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENV HOME=/home/multica
WORKDIR /home/multica/multica_workspaces
USER multica

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["--no-auto-update"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]

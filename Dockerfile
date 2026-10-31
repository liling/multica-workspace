# syntax=docker/dockerfile:1
#
# Multica workspace image.
#
# Build source policy:
#   BUILD_SOURCE=official  -> upstream/original sources (used by GitHub Actions)
#   BUILD_SOURCE=cn        -> China-friendly mirrors (default for local/on-prem builds)
#
# China mode currently switches:
#   - Debian APT -> TUNA mirrors
#   - Node.js dist -> USTC mirror
#   - npm registry -> npmmirror
#   - GitHub release assets -> configurable GitHub proxy prefix
#
# All mirror endpoints can still be overridden with build args so a site can use its own mirror.

ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

ARG BUILD_SOURCE=cn
ARG DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
ARG DEBIAN_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian-security
ARG NODE_MIRROR=https://mirrors.ustc.edu.cn/node
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG GITHUB_PROXY_PREFIX=https://ghfast.top/

# Configure Debian package sources before the first apt operation.
# Debian trixie uses deb822 sources in /etc/apt/sources.list.d/debian.sources.
RUN set -eux; \
    case "$BUILD_SOURCE" in \
      official) echo "Using official build sources" ;; \
      cn) \
        echo "Using China build mirrors"; \
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
        fi \
        ;; \
      *) echo "Unsupported BUILD_SOURCE=${BUILD_SOURCE}; expected official or cn" >&2; exit 2 ;; \
    esac

# Base development and troubleshooting tools.
# Network toolbox:
#   dnsutils       -> host, dig, nslookup
#   iputils-ping   -> ping
#   wget           -> wget
#   iproute2       -> ip, ss
#   netcat-openbsd -> nc
#   traceroute     -> traceroute
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

# Install Node 24 directly from the official Node.js distribution directory or a China mirror.
# This avoids depending on the NodeSource apt repository, whose China mirrors are not reliably
# synchronized. The latest v24.x artifact is selected from SHASUMS256.txt for the current arch.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "Unsupported Node architecture: $(dpkg --print-architecture)" >&2; exit 2 ;; \
    esac; \
    if [ "$BUILD_SOURCE" = cn ]; then \
      NODE_BASE="${NODE_MIRROR%/}/latest-v24.x"; \
    else \
      NODE_BASE="https://nodejs.org/dist/latest-v24.x"; \
    fi; \
    NODE_FILE="$(curl -fsSL "$NODE_BASE/SHASUMS256.txt" \
      | awk -v arch="$NODE_ARCH" '$2 ~ ("node-v[0-9.]+-linux-" arch "\\.tar\\.xz$") {print $2; exit}')"; \
    test -n "$NODE_FILE"; \
    echo "Installing Node from $NODE_BASE/$NODE_FILE"; \
    curl -fsSL "$NODE_BASE/$NODE_FILE" -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm /tmp/node.tar.xz; \
    node --version; \
    npm --version

# npm packages use npmmirror in China mode and the upstream npm registry in official mode.
RUN set -eux; \
    if [ "$BUILD_SOURCE" = cn ]; then npm config set registry "$NPM_REGISTRY"; fi; \
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.4.0; \
    npm install -g @openai/codex@0.164.0 chrome-devtools-mcp@1.12.0; \
    npm install -g --allow-scripts=pnpm pnpm@12.15.0

# Install the requested Multica CLI release. In China mode GitHub release downloads are routed
# through GITHUB_PROXY_PREFIX; set it to an empty string or a site-local proxy if desired.
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
    upstream="https://github.com/multica-ai/multica/releases/download/${MULTICA_VERSION}/multica-cli-${version}-linux-${MULTICA_ARCH}.tar.gz"; \
    if [ "$BUILD_SOURCE" = cn ] && [ -n "$GITHUB_PROXY_PREFIX" ]; then \
        download_url="${GITHUB_PROXY_PREFIX}${upstream}"; \
    else \
        download_url="$upstream"; \
    fi; \
    echo "Installing Multica CLI target: ${MULTICA_VERSION} (linux/${MULTICA_ARCH})"; \
    echo "Download source: ${download_url}"; \
    curl -fsSL "$download_url" -o /tmp/multica.tar.gz; \
    tar -xzf /tmp/multica.tar.gz -C /usr/local/bin multica; \
    chmod 0755 /usr/local/bin/multica; \
    rm /tmp/multica.tar.gz; \
    actual="$(multica version)"; \
    echo "Multica CLI target: ${MULTICA_VERSION}; installed: ${actual}"; \
    [ "$(printf '%s\n' "$actual" | awk 'NR==1 {print $1 " " $2}')" = "multica ${version}" ]

RUN groupadd --gid 1000 multica \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/multica --shell /bin/bash multica \
    && install -d -o 1000 -g 1000 -m 0700 /home/multica/.ssh \
    && install -d -o 1000 -g 1000 -m 0755 /home/multica/.multica /home/multica/.pi/agent /home/multica/.codex /home/multica/.config/gh /home/multica/multica_workspaces \
    && install -d -o 1000 -g 1000 -m 0755 /run/multica-workspace \
    && printf '%s\n' 'multica ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/multica \
    && chmod 0440 /etc/sudoers.d/multica \
    && visudo -cf /etc/sudoers.d/multica

# Verify the tool contract as the runtime user, including the network diagnostics toolbox.
RUN set -eux; \
    su -s /bin/bash multica -c 'set -euo pipefail; id -u; id -g; test "$HOME" = /home/multica; \
      pi --version; codex --version; multica version; gh --version; docker --version; \
      chromium --version; chrome-devtools-mcp --version; python3 --version; jq --version; pnpm --version; \
      command -v host; command -v dig; command -v nslookup; command -v ping; command -v wget; \
      command -v ip; command -v ss; command -v nc; command -v traceroute; \
      sudo -n id -u | grep -qx 0; test "$(id -u)" = 1000'; \
    test "$(stat -c %a:%u:%g /home/multica/.ssh)" = 700:1000:1000; \
    test "$(stat -c %a:%u:%g /run/multica-workspace)" = 755:1000:1000

RUN set -eux; \
    pi --version; \
    codex --version; \
    test "$(pi --version)" = "1.4.0"; \
    test "$(codex --version)" = "codex-cli 0.164.0"; \
    test "$(pnpm --version)" = "12.15.0"; \
    test "$(chrome-devtools-mcp --version)" = "1.12.0"; \
    multica version; \
    gh --version; \
    docker --version; chromium --version; python3 --version; jq --version; pnpm --version; \
    host -V 2>&1 | head -n 1; ping -V; wget --version | head -n 1; ip -V; traceroute --version 2>&1 | head -n 1; \
    npx --no-install chrome-devtools-mcp --help >/dev/null; \
    echo "All workstation tools are available at their pinned versions."

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENV HOME=/home/multica
WORKDIR /home/multica/multica_workspaces
USER multica

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["--no-auto-update"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]

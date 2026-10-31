#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dockerfile="$root/Dockerfile"
bootstrap="$root/Dockerfile.bootstrap"
compose="$root/compose.yaml"

# The server-side Dockerfile must not fetch GitHub release/API content.
grep -Fq 'ARG BOOTSTRAP_IMAGE=' "$dockerfile"
! grep -Eq 'github\.com/multica-ai|api\.github\.com|MULTICA_VERSION' "$dockerfile"

# TUNA is the preferred server-side mirror for Debian and Node.
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/debian' "$dockerfile"
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/debian-security' "$dockerfile"
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/nodejs-release' "$dockerfile"
grep -Fq 'https://registry.npmmirror.com' "$dockerfile"

# GitHub-only Multica download belongs exclusively to the bootstrap image.
grep -Fq 'https://api.github.com/repos/multica-ai/multica/releases/latest' "$bootstrap"
grep -Fq 'https://github.com/multica-ai/multica/releases/download/' "$bootstrap"

# Compose builds the final image locally instead of pulling the old monolithic image.
grep -Fq 'dockerfile: Dockerfile' "$compose"
grep -Fq 'BOOTSTRAP_IMAGE:' "$compose"
grep -Fq 'nodejs-release' "$compose"

# Preserve the runtime identity and supervisor contract.
grep -Eq '^ENV HOME=/home/multica$' "$dockerfile"
grep -Eq '^WORKDIR /home/multica/multica_workspaces$' "$dockerfile"
grep -Eq '^USER multica$' "$dockerfile"
grep -Fq 'useradd --uid 1000 --gid 1000 --create-home --home-dir /home/multica --shell /bin/bash multica' "$dockerfile"
grep -Fq 'install -d -o 1000 -g 1000 -m 0700 /home/multica/.ssh' "$dockerfile"
grep -Fq 'install -d -o 1000 -g 1000 -m 0755 /run/multica-workspace' "$dockerfile"
grep -Fq "multica ALL=(ALL) NOPASSWD: ALL" "$dockerfile"
! grep -Eq '/root/|chmod[[:space:]]+666.*docker.sock|docker.sock.*chmod[[:space:]]+666' "$dockerfile"
grep -Fq 'sudo -n id -u | grep -qx 0' "$dockerfile"
grep -Fq 'chromium --version' "$dockerfile"

if [[ $(id -u) -eq 0 ]]; then
  echo 'Run this suite as an unprivileged user to verify supervisor UID behavior.' >&2
  exit 1
fi
bash "$root/tests/supervisor.sh"
echo 'image contract tests passed'

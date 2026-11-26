#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dockerfile="$root/Dockerfile"
bootstrap="$root/Dockerfile.bootstrap"
compose="$root/compose.yaml"

# The server-side Dockerfile must not fetch GitHub release/API content.
grep -Fq 'ARG BOOTSTRAP_IMAGE=' "$dockerfile"
! grep -Eq 'github\.com/multica-ai|api\.github\.com|MULTICA_VERSION' "$dockerfile"

# TUNA is the preferred server-side mirror for Debian and PyPI.
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/debian' "$dockerfile"
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/debian-security' "$dockerfile"
grep -Fq 'https://mirrors.tuna.tsinghua.edu.cn/nodejs-release' "$dockerfile"
grep -Fq 'https://pypi.tuna.tsinghua.edu.cn/simple' "$dockerfile"
grep -Fq 'https://registry.npmmirror.com' "$dockerfile"

# GitHub-only Multica download belongs exclusively to the pinned bootstrap image.
! grep -Fq 'https://api.github.com/repos/multica-ai/multica/releases/latest' "$bootstrap"
grep -Fq 'https://github.com/multica-ai/multica/releases/download/' "$bootstrap"
grep -Fq 'https://codeload.github.com/NousResearch/hermes-agent/tar.gz/${HERMES_COMMIT}' "$bootstrap"
grep -Fq '8fc0374447313e276f6b9a2764bfc750190c966a' "$bootstrap"
grep -Fq '620bf64a63c7fabd995df402e46d5eee0cdab7e5d01a4aeddc3a6fa5dee54cc0' "$bootstrap"
grep -Fq 'https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_STANDALONE_RELEASE}/${python_asset}' "$bootstrap"
grep -Fq 'PYTHON_BUILD_STANDALONE_RELEASE=20261124' "$bootstrap"
grep -Fq 'bfa2f9fe1691f14a98c37e206641058ad7116db117ac924fdcab744987107ad8' "$bootstrap"
grep -Fq '4a5d38d83b7cab3b1ee53b9fe398ba5bf43d737acca4f7bc06b9deb6ac0e7405' "$bootstrap"

# Keep pinned CLI and Hermes versions in sync with the published image tag.
bootstrap_version=$(sed -n 's/^ARG MULTICA_VERSION=v//p' "$bootstrap")
workflow_version=$(sed -n 's/^  MULTICA_VERSION: //p' "$root/.github/workflows/docker-build.yml")
[[ -n "$bootstrap_version" && "$bootstrap_version" == "$workflow_version" ]]
hermes_version=$(sed -n 's/^ARG HERMES_VERSION=v//p' "$bootstrap")
workflow_hermes_version=$(sed -n 's/^  HERMES_VERSION: //p' "$root/.github/workflows/docker-build.yml")
[[ -n "$hermes_version" && "$hermes_version" == "$workflow_hermes_version" ]]
grep -Fq '82b2b92891f4b51344facfa9f917f067a926453315c6bb87d1f02294635fc4ec' "$bootstrap"
grep -Fq '1f18a986f612f4291400914b24351d52f3d8502e64b03381db74fbb444493012' "$bootstrap"
grep -Fq '0.13.0-hermes-0.23.4' "$compose"
grep -Fq 'hermes-state:/home/multica/.hermes' "$compose"
grep -Fq 'unset HERMES_HOME HERMES_WRITE_SAFE_ROOT' "$root/entrypoint.sh"
grep -Fq 'hermes acp --check' "$dockerfile"
grep -Fq 'UV_PYTHON_DOWNLOADS=never' "$dockerfile"
! grep -Fq 'UV_NO_MANAGED_PYTHON=' "$dockerfile"
grep -Fq 'exclude-newer = false' "$dockerfile"
grep -Fq 'uv export --frozen' "$dockerfile"
grep -Fq -- '--no-sources-package psutil --no-default-groups --extra acp' "$dockerfile"
grep -Fq 'uv pip sync --require-hashes' "$dockerfile"
grep -Fq 'scripts/write_install_stamp.py' "$dockerfile"
grep -Fq 'HERMES_VERSION=0.23.4' "$dockerfile"
grep -Fq 'psutil.git/d' "$dockerfile"
grep -Fq 'ARG PYTHON_VERSION=3.14.10' "$dockerfile"
grep -Fq 'tar -xzf /opt/python-install-only.tar.gz' "$dockerfile"
grep -Fq 'rm /opt/python-install-only.tar.gz' "$dockerfile"
grep -Fq 'uv venv --python' "$dockerfile"
grep -Fq 'ENV PATH="/opt/hermes/.venv/bin:/opt/python/${PYTHON_VERSION}/bin:${PATH}"' "$dockerfile"
! grep -Fq 'HERMES_IMAGE=' "$root/.github/workflows/docker-build.yml"
grep -Fq 'push: ${{ github.event_name != '\''pull_request'\'' }}' "$root/.github/workflows/docker-build.yml"

# Compose builds the final image locally instead of pulling the old monolithic image.
grep -Fq 'dockerfile: Dockerfile' "$compose"
grep -Fq 'BOOTSTRAP_IMAGE:' "$compose"
grep -Fq 'nodejs-release' "$compose"
grep -Fq 'PYPI_MIRROR:' "$compose"

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
# Guard is included without a GitHub fetch in the server-side build.
grep -Fq 'COPY --chmod=0644 guard-vnext/*.py /etc/codex/hooks/guard-vnext/' "$dockerfile"
grep -Fq 'COPY --chmod=0644 guard-vnext/codex-system.toml /etc/codex/config.toml' "$dockerfile"

if [[ $(id -u) -eq 0 ]]; then
  echo 'Run this suite as an unprivileged user to verify supervisor UID behavior.' >&2
  exit 1
fi
bash "$root/tests/supervisor.sh"
echo 'image contract tests passed'

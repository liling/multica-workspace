#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dockerfile="$root/Dockerfile"

grep -Eq '^ENV HOME=/home/multica$' "$dockerfile"
grep -Eq '^WORKDIR /home/multica/multica_workspaces$' "$dockerfile"
grep -Eq '^USER multica$' "$dockerfile"
grep -Fq 'useradd --uid 1000 --gid 1000 --create-home --home-dir /home/multica --shell /bin/bash multica' "$dockerfile"
grep -Fq 'install -d -o 1000 -g 1000 -m 0700 /home/multica/.ssh' "$dockerfile"
grep -Fq 'install -d -o 1000 -g 1000 -m 0755 /run/multica-workspace' "$dockerfile"
grep -Fq "multica ALL=(ALL) NOPASSWD: ALL" "$dockerfile"
! grep -Eq '/root/|chmod[[:space:]]+666.*docker.sock|docker.sock.*chmod[[:space:]]+666' "$dockerfile"

grep -Fq 'sudo -n id -u | grep -qx 0' "$dockerfile"
grep -Fq 'test "$(id -u)" = 1000' "$dockerfile"
grep -Fq 'chromium --version' "$dockerfile"
grep -Fq 'USER multica' "$dockerfile"

if [[ $(id -u) -eq 0 ]]; then
  echo 'Run this suite as an unprivileged user to verify supervisor UID behavior.' >&2
  exit 1
fi
bash "$root/tests/supervisor.sh"
echo 'image contract tests passed'

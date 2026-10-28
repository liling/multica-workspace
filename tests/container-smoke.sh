#!/usr/bin/env bash
set -euo pipefail
image=${1:?usage: tests/container-smoke.sh <image>}
name="multica-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

identity=$(docker run --rm --entrypoint sh "$image" -lc 'id -u; id -g; whoami; echo "$HOME"; pwd')
expected=$(printf '1000\n1000\nmultica\n/home/multica\n/home/multica/multica_workspaces')
[[ "$identity" == "$expected" ]]

docker run --rm --entrypoint sh "$image" -lc '
  set -e
  pi --version
  codex --version
  multica version
  gh --version
  docker --version
  chromium --version
  chrome-devtools-mcp --version
  python3 --version
  jq --version
  pnpm --version
  test "$(id -u)" = 1000
  test "$(sudo -n id -u)" = 0
'

docker run -d --name "$name" "$image" >/dev/null
for _ in $(seq 1 60); do
  [[ "$(docker inspect -f '{{.State.Status}}' "$name")" == running ]] || break
  status=$(docker exec "$name" cat /run/multica-workspace/status 2>/dev/null || true)
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)
  if [[ "$status" == auth-missing && "$health" == unhealthy ]]; then break; fi
  sleep 2
done
[[ "$(docker inspect -f '{{.State.Status}}' "$name")" == running ]]
[[ "$(docker exec "$name" cat /run/multica-workspace/status)" == auth-missing ]]
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == unhealthy ]]
docker stop --time 10 "$name" >/dev/null
[[ "$(docker inspect -f '{{.State.Status}}' "$name")" == exited ]]
[[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" == 0 ]]
echo 'container smoke tests passed: identity, tools, sudo, missing-auth health, stop'

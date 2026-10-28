#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'kill ${supervisor_pid:-} 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/multica" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'auth status') [[ -f "$MOCK_AUTH" ]] ;;
  'login --token '* ) touch "$MOCK_AUTH" ;;
  'daemon start --foreground --no-auto-update') exec sleep 300 ;;
esac
MOCK
chmod +x "$tmp/bin/multica"
export PATH="$tmp/bin:$PATH" MOCK_AUTH="$tmp/auth" MULTICA_STATE_DIR="$tmp/state" MULTICA_TOKEN=valid HOSTNAME=test
"$root/entrypoint.sh" --no-auto-update & supervisor_pid=$!
for _ in {1..100}; do [[ -f "$tmp/state/status" && $(cat "$tmp/state/status") == healthy ]] && break; sleep .1; done
[[ $(cat "$tmp/state/status") == healthy ]]
"$root/healthcheck.sh"
kill -TERM "$supervisor_pid"
wait "$supervisor_pid"
[[ $(cat "$tmp/state/status") == stopped ]]
[[ ! -e "$tmp/state/daemon.pid" ]]
echo 'supervisor lifecycle test passed'

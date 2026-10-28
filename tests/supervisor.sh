#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
supervisor_pid=""
cleanup() {
  if [[ -n "$supervisor_pid" ]]; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/multica" <<'MOCK'
#!/usr/bin/env bash
set -u
case "$*" in
  'auth status') [[ "${MOCK_AUTH_OK:-0}" == 1 ]] ;;
  'login --token '* ) [[ "${MOCK_LOGIN_OK:-0}" == 1 ]] ;;
  'daemon start --foreground --no-auto-update')
    attempt_file="$MULTICA_STATE_DIR/daemon-attempts"
    attempt=0
    [[ ! -f "$attempt_file" ]] || attempt=$(cat "$attempt_file")
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$attempt_file"
    if [[ "${MOCK_DAEMON_MODE:-stable}" == startup-failure && "$attempt" == 1 ]]; then
      exit 23
    fi
    exec sleep 300
    ;;
esac
MOCK
chmod +x "$tmp/bin/multica"

start_supervisor() {
  local name=$1
  mkdir -p "$tmp/$name/state"
  export PATH="$tmp/bin:$PATH"
  export MULTICA_STATE_DIR="$tmp/$name/state"
  export HOSTNAME=test
  "$root/entrypoint.sh" --no-auto-update &
  supervisor_pid=$!
  actual_uid=$(ps -o uid= -p "$supervisor_pid" | tr -d ' ')
  [[ "$actual_uid" == "$(id -u)" && "$actual_uid" != 0 ]]
}
wait_status() {
  local expected=$1 timeout=${2:-12}
  for ((i=0; i<timeout*10; i++)); do
    if [[ -f "$MULTICA_STATE_DIR/status" && "$(cat "$MULTICA_STATE_DIR/status")" == "$expected" ]]; then return 0; fi
    sleep .1
  done
  echo "timed out waiting for status=$expected; got $(cat "$MULTICA_STATE_DIR/status" 2>/dev/null || echo missing)" >&2
  return 1
}
assert_unhealthy() {
  if "$root/healthcheck.sh"; then
    echo "healthcheck unexpectedly succeeded in status $(cat "$MULTICA_STATE_DIR/status")" >&2
    return 1
  fi
}
stop_supervisor() {
  kill -TERM "$supervisor_pid"
  wait "$supervisor_pid"
  supervisor_pid=""
  [[ $(cat "$MULTICA_STATE_DIR/status") == stopped ]]
  [[ ! -e "$MULTICA_STATE_DIR/daemon.pid" ]]
}

# Missing credentials must leave the supervisor alive and unhealthy.
unset MULTICA_TOKEN || true
export MOCK_AUTH_OK=0 MOCK_LOGIN_OK=0 MOCK_DAEMON_MODE=stable
start_supervisor missing-token
wait_status auth-missing
assert_unhealthy
kill -0 "$supervisor_pid"
stop_supervisor

# Rejected login tokens also leave the supervisor alive and unhealthy.
export MULTICA_TOKEN=invalid
start_supervisor auth-failure
wait_status auth-failed
assert_unhealthy
kill -0 "$supervisor_pid"
stop_supervisor

# A daemon that fails during startup is retried after backoff and becomes healthy.
export MOCK_AUTH_OK=1 MOCK_DAEMON_MODE=startup-failure
unset MULTICA_TOKEN || true
start_supervisor startup-recovery
wait_status daemon-exited
assert_unhealthy
[[ $(cat "$MULTICA_STATE_DIR/daemon-attempts") == 1 ]]
wait_status healthy 20
[[ $(cat "$MULTICA_STATE_DIR/daemon-attempts") -ge 2 ]]
"$root/healthcheck.sh"
stop_supervisor

# Killing a healthy daemon flips health, then a later attempt restores it.
export MOCK_DAEMON_MODE=stable
start_supervisor runtime-recovery
wait_status healthy
first_pid=$(cat "$MULTICA_STATE_DIR/daemon.pid")
kill -KILL "$first_pid"
wait_status daemon-exited 5
assert_unhealthy
wait_status healthy 20
second_pid=$(cat "$MULTICA_STATE_DIR/daemon.pid")
[[ "$second_pid" != "$first_pid" ]]
"$root/healthcheck.sh"
stop_supervisor

echo 'supervisor lifecycle tests passed: missing auth, auth failure, startup retry, runtime recovery, SIGTERM'

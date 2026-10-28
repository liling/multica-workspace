#!/usr/bin/env bash
set -u

STATE_DIR=${MULTICA_STATE_DIR:-/run/multica-workspace}
mkdir -p "$STATE_DIR"
STATUS_FILE="$STATE_DIR/status"
PID_FILE="$STATE_DIR/daemon.pid"
ERROR_FILE="$STATE_DIR/last-error"
daemon_pid=""
stop=0

write_status() { printf '%s\n' "$1" >"$STATUS_FILE"; }
write_error() { printf '%s\n' "$*" >"$ERROR_FILE"; }
cleanup() {
  stop=1
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  write_status stopped
}
trap cleanup TERM INT HUP

if [[ -n "${MULTICA_DEBUG_SHELL:-}" ]]; then exec "${SHELL:-/bin/bash}" "$@"; fi
if [[ $# -gt 0 && "$1" != "--no-auto-update" ]]; then exec "$@"; fi

backoff=5
while (( ! stop )); do
  write_status starting
  if ! multica auth status >/tmp/multica-auth.log 2>&1; then
    if [[ -z "${MULTICA_TOKEN:-}" ]]; then
      write_status auth-missing
      write_error 'MULTICA_TOKEN is missing and persisted authentication is invalid'
    elif ! multica login --token "$MULTICA_TOKEN" >/tmp/multica-login.log 2>&1 || ! multica auth status >/tmp/multica-auth-check.log 2>&1; then
      write_status auth-failed
      write_error "Authentication failed: $(tail -n 1 /tmp/multica-login.log 2>/dev/null || tail -n 1 /tmp/multica-auth.log)"
    else
      :
    fi
  fi
  if [[ "$(cat "$STATUS_FILE")" != auth-missing && "$(cat "$STATUS_FILE")" != auth-failed ]]; then
    export MULTICA_DAEMON_DEVICE_NAME=${HOSTNAME:-multica-workspace}
    multica daemon start --foreground --no-auto-update &
    daemon_pid=$!
    printf '%s\n' "$daemon_pid" >"$PID_FILE"
    sleep 2
    if kill -0 "$daemon_pid" 2>/dev/null; then
      write_status healthy
      rm -f "$ERROR_FILE"
      while kill -0 "$daemon_pid" 2>/dev/null && (( ! stop )); do sleep 1; done
    fi
    wait "$daemon_pid"; rc=$?
    daemon_pid=""
    rm -f "$PID_FILE"
    if (( ! stop )); then
      write_status daemon-exited
      write_error "multica daemon exited with status $rc"
    fi
  fi
  (( stop )) && break
  sleep "$backoff" & wait $! || true
  backoff=$(( backoff < 60 ? backoff * 3 : 60 ))
done

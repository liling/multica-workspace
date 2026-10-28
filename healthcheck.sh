#!/usr/bin/env bash
set -eu
state_dir=${MULTICA_STATE_DIR:-/run/multica-workspace}
[[ -f "$state_dir/status" && "$(cat "$state_dir/status")" == healthy ]]
[[ -s "$state_dir/daemon.pid" ]]
pid=$(cat "$state_dir/daemon.pid")
kill -0 "$pid" 2>/dev/null

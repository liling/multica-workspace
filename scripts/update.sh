#!/usr/bin/env bash
set -euo pipefail

# Explicit software refresh path. Runtime startup never installs packages.
# --pull refreshes the bootstrap image and --no-cache forces APT/Node/npm layers
# to be resolved again from the configured China-friendly mirrors.
docker compose build --pull --no-cache agent
docker compose up -d agent
docker compose ps agent

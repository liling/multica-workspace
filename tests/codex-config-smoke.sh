#!/usr/bin/env bash
set -euo pipefail

codex_home=$(mktemp -d "$HOME/.codex-smoke.XXXXXX")
trap 'rm -rf "$codex_home"' EXIT
export CODEX_HOME=$codex_home

codex mcp list | grep -q '^gitnexus'
mkdir -p "$CODEX_HOME/skills/gitnexus-cli"
printf '%s\n' 'user skill stays' > "$CODEX_HOME/skills/gitnexus-cli/USER.md"
printf '%s\n' \
  '[mcp_servers.gitnexus]' \
  'command = "/bin/echo"' \
  'args = ["user-config"]' > "$CODEX_HOME/config.toml"
codex mcp list | grep -q '/bin/echo.*user-config'
test "$(cat "$CODEX_HOME/skills/gitnexus-cli/USER.md")" = 'user skill stays'

echo 'Codex system MCP is inherited; user config and skill remain intact'

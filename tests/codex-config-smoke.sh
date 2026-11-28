#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CODEX_HOME:-}" ]]; then
  codex_home=$CODEX_HOME
  mkdir -p "$codex_home"
else
  codex_home=$(mktemp -d "$HOME/.codex-smoke.XXXXXX")
  trap 'rm -rf "$codex_home"' EXIT
fi
export CODEX_HOME=$codex_home

mkdir -p "$CODEX_HOME/skills/gitnexus-cli"
printf '%s\n' 'user skill stays' > "$CODEX_HOME/skills/gitnexus-cli/USER.md"
printf '%s\n' '---' 'name: gitnexus-cli' 'description: User override smoke fixture.' '---' '' 'User skill stays.' \
  > "$CODEX_HOME/skills/gitnexus-cli/SKILL.md"
test "$(cat "$CODEX_HOME/skills/gitnexus-cli/USER.md")" = 'user skill stays'
grep -Fq 'description: User override smoke fixture.' "$CODEX_HOME/skills/gitnexus-cli/SKILL.md"

python3 /tmp/codex-app-server-smoke.py "$CODEX_HOME"
printf '%s\n' \
  '[mcp_servers.gitnexus]' \
  'command = "/bin/echo"' \
  'args = ["user-config"]' > "$CODEX_HOME/config.toml"
codex mcp list | grep -q '/bin/echo.*user-config'
test "$(cat "$CODEX_HOME/skills/gitnexus-cli/USER.md")" = 'user skill stays'
grep -Fq 'description: User override smoke fixture.' "$CODEX_HOME/skills/gitnexus-cli/SKILL.md"

echo 'Codex app-server skills and MCP calls passed; user config and skill remain intact'

#!/usr/bin/env bash
# Offline build contract: pinned source bytes, registered Stop hook and 3-block semantics.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/guard-vnext/source-manifest.txt"
grep -Fxq 'source_commit db313fa2df91fdf9c267c9354741cde51fd9ac65' "$manifest"
[[ $(grep -c '^blob ' "$manifest") -eq 5 ]]
for name in guard_vnext.py identity_guard.py multica_provider.py observe_stop.py uep_feedback.py; do
  line="$(grep -E "^blob $name " "$manifest")"
  read -r kind filename expected <<< "$line"
  [[ "$kind" == blob && "$filename" == "$name" ]]
  actual="$(git hash-object "$root/guard-vnext/$name")"
  [[ "$actual" == "$expected" ]] || {
    echo "Guard source drift: $name expected $expected actual $actual" >&2
    exit 1
  }
done
python3 - "$root" <<'PY'
import json
import sqlite3
import sys
import tempfile
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "guard-vnext"))
import guard_vnext
from uep_feedback import check_feedback, parse_comment
from multica_provider import ProviderRead

config = tomllib.loads((root / "guard-vnext/codex-system.toml").read_text())
hooks = config["hooks"]["Stop"]
assert len(hooks) == 1
assert hooks[0]["hooks"] == [{
    "type": "command",
    "command": "python3 /etc/codex/hooks/guard-vnext/observe_stop.py",
    "timeout": 8,
}]
assert guard_vnext.MAX_BLOCKS == 3

malformed_multiline_result = (
    "UEP_FEEDBACK: 1\nSTATE: RUN_UNIT_DONE\nRESULT: 第一段事实\n"
    "补充证据细节\nNEXT: NONE"
)
malformed_verdict, malformed_fields = parse_comment(malformed_multiline_result)
assert malformed_verdict == {
    "result": "SUSPECT_INCOMPLETE",
    "reason": "malformed_next_line",
}, malformed_verdict
assert malformed_fields is None

valid_threaded_feedback = {
    "id": "threaded-feedback",
    "author_id": "770c0801-3bb3-45c5-9d7c-b0fe2c7a83e2",
    "source_task_id": "01a1b8f2-4620-745e-afbb-a9e86b296fd2",
    "issue_id": "01a1b8c6-29b7-7dc5-a8fb-2a4b36f00070",
    "parent_id": "01a1b8f2-4620-745e-afbb-a9e86b296fd2",
    "type": "comment",
    "created_at": "2026-11-10T00:00:00Z",
    "content": (
        "UEP_FEEDBACK: 1\nSTATE: RUN_UNIT_DONE\nRESULT: 本轮定向测试通过。\n"
        "NEXT: NONE\n\n补充证据细节。"
    ),
}
threaded_result = check_feedback(
    [valid_threaded_feedback],
    "01a1b8f2-4620-745e-afbb-a9e86b296fd2",
    "770c0801-3bb3-45c5-9d7c-b0fe2c7a83e2",
    "01a1b8c6-29b7-7dc5-a8fb-2a4b36f00070",
)
assert threaded_result["result"] == "NORMAL_INTENTIONAL_END", threaded_result
assert threaded_result["feedback_comment_id"] == "threaded-feedback"

class FakeProvider:
    def __init__(self, no_action=False):
        self.no_action = no_action

    def fetch_comments(self, issue_id, workspace_id):
        return ProviderRead([], True, None)

    def has_no_action(self, issue_id, workspace_id, run_id):
        return ProviderRead(self.no_action, True, None)

with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root / ".multica").mkdir()
    issue_id = "01a1b8c6-29b7-7dc5-a8fb-2a4b36f00070"
    agent_id = "770c0801-3bb3-45c5-9d7c-b0fe2c7a83e2"
    (root / ".multica/daemon_task_context.json").write_text(
        json.dumps({"issue_id": issue_id, "agent_id": agent_id}))
    env = {
        "MULTICA_TASK_ID": "01a1b8f2-4620-745e-afbb-a9e86b296fd2",
        "MULTICA_AGENT_ID": agent_id,
        "MULTICA_WORKSPACE_ID": "749b6e7f-888a-490a-b41e-a0ad083c709e",
        "MULTICA_GUARD_STATE": str(root / "budget.sqlite3"),
    }
    def stop(turn, active):
        return json.dumps({"hook_event_name": "Stop", "turn_id": turn,
                           "stop_hook_active": active})
    provider = FakeProvider()
    for n in range(1, 4):
        result = guard_vnext.shadow_observe(
            stop("one-turn", n > 1), env, provider, start_dir=root)
        assert result["guard_decision"]["decision"] == "block", result
        assert result["guard_decision"]["reason"].startswith(
            f"missing_feedback_block_{n}/3:"), result
    result = guard_vnext.shadow_observe(
        stop("one-turn", True), env, provider, start_dir=root)
    assert result["hook_output"] == {"continue": True}, result
    assert result["guard_decision"]["reason"] == "retry_exhausted_allow", result
    with sqlite3.connect(root / "budget.sqlite3") as db:
        assert db.execute("SELECT count FROM stop_budget").fetchone()[0] == 4
    result = guard_vnext.shadow_observe(
        stop("next-turn", False), env, provider, start_dir=root)
    assert result["guard_decision"]["decision"] == "block"
    result = guard_vnext.shadow_observe(
        stop("no-action-turn", False), env, FakeProvider(True), start_dir=root)
    assert result["guard_decision"] == {
        "decision": "ALLOW",
        "reason": "no_action_verified_allow",
    }, result
print("guard contract PASS: exact pin, system hook config, three blocks, bounded allow, no_action")
PY

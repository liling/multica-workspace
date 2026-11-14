#!/usr/bin/env bash
# Offline build contract: pinned source bytes, registered Stop hook and 3-block semantics.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/guard-vnext/source-manifest.txt"
grep -Fxq 'source_commit f53beffb29638e324fd7b264a305ebd5a009503e' "$manifest"
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
from multica_provider import ProviderRead
from uep_feedback import parse_comment, check_feedback

# Old K3 feedback must continue to work while deployed agents are unchanged.
legacy = "UEP_FEEDBACK: 1\nSTATE: DELIVERED\nRESULT: 完成。\nNEXT: NONE"
assert parse_comment(legacy)[0]["reason"] == "uep_feedback_valid"
legacy_multiline = "UEP_FEEDBACK: 1\nSTATE: DELIVERED\nRESULT: 完成。\n多行\nNEXT: NONE"
assert parse_comment(legacy_multiline)[0]["reason"] == "malformed_next_line"

# K4 RESULT spans all remaining lines; a NEXT-like text line is not a header.
k4 = ("UEP_FEEDBACK: 1\nSTATE: RUN_UNIT_DONE\nNEXT: NONE\nRESULT:\n"
      "完成。\n- 23 tests\nNEXT: HANDOFF")
assert parse_comment(k4)[0]["reason"] == "uep_feedback_valid"
assert parse_comment("UEP_FEEDBACK: 1\nSTATE: DELIVERED\nNEXT: NONE\nRESULT: ")[0]["reason"] == "empty_result"

target = "18c9e9f4-3247-4826-9d4e-086ba8e2b192"
mention = f"[@浩宇](mention://agent/{target}) 请验收"
k4_handoff = ("UEP_FEEDBACK: 1\nSTATE: RUN_UNIT_DONE\nNEXT: HANDOFF\nRESULT:\n"
              "PR #123 完成\n" + mention)
assert parse_comment(k4_handoff)[1]["target_agent_id"] == target
assert parse_comment(k4_handoff + "\n" + mention)[0]["reason"] == "handoff_target_ambiguous"
assert parse_comment(k4_handoff.replace("HANDOFF", "NONE", 1))[0]["reason"] == "unexpected_agent_mention"

run, agent, issue = "run-a", "agent-a", "issue-a"
record = {"id": "comment-a", "author_id": agent, "source_task_id": run,
          "issue_id": issue, "type": "comment", "created_at": "2026-11-14T00:00:00Z",
          "content": k4}
assert check_feedback([record], run, agent, issue)["result"] == "NORMAL_INTENTIONAL_END"
assert check_feedback([record], "other-run", agent, issue)["result"] == "SUSPECT_MISSING_FEEDBACK"
assert check_feedback([record], run, "other-agent", issue)["result"] == "SUSPECT_MISSING_FEEDBACK"
assert check_feedback([record], run, agent, "other-issue")["result"] == "UNKNOWN_ALLOW"

# Thread-reply binding, retained from the superseded MEM-773 PR #36.
threaded = {**record, "id": "threaded-feedback",
            "parent_id": "trigger-comment-id", "content": legacy}
threaded_result = check_feedback([threaded], run, agent, issue)
assert threaded_result["result"] == "NORMAL_INTENTIONAL_END", threaded_result
assert threaded_result["feedback_comment_id"] == "threaded-feedback", threaded_result
assert check_feedback([threaded], "different-run", agent, issue)["result"] == "SUSPECT_MISSING_FEEDBACK"


config = tomllib.loads((root / "guard-vnext/codex-system.toml").read_text())
hooks = config["hooks"]["Stop"]
assert len(hooks) == 1
assert hooks[0]["hooks"] == [{
    "type": "command",
    "command": "python3 /etc/codex/hooks/guard-vnext/observe_stop.py",
    "timeout": 8,
}]
assert guard_vnext.MAX_BLOCKS == 3

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
print("guard contract PASS: exact pin, K3/K4 parser, identity binding, system hook config, three blocks, bounded allow, no_action")
PY

"""Codex Stop guard for persisted Multica UEP feedback.

Identity is taken from the process
environment (``MULTICA_TASK_ID`` / ``MULTICA_AGENT_ID`` /
``MULTICA_WORKSPACE_ID``); the local ``.multica/daemon_task_context.json`` is
used solely to locate the Issue and never to judge which Run is current.
"""
import json
import hashlib
import os
import sqlite3
import sys
import time
from pathlib import Path

from multica_provider import MulticaReadOnlyProvider, resolve_local_context
from uep_feedback import check_feedback

MAX_HOOK_BYTES = 65536
MAX_BLOCKS = 3
STATE_TTL_SECONDS = 7 * 24 * 60 * 60


def _observation(reason):
    return {"identity_trust": "unverified", "result": "UNKNOWN_ALLOW", "reason": reason}

def _result(decision, reason, feedback=None):
    output = {
        "guard_decision": {"decision": decision, "reason": reason},
        "observed_feedback": feedback or _observation(reason),
    }
    if decision == "block":
        output["hook_output"] = {"decision": "block", "reason": reason}
    else:
        output["hook_output"] = {"continue": True}
    return output


def shadow_observe(hook_json, environ, provider, start_dir=None):
    """Judge one Stop using exact current-Issue/Run/Agent Comment associations.

    A block only asks Codex's synchronous Stop protocol for one continuation;
    it never creates a successor Run or restores a crashed Runtime process.
    """
    try:
        event = json.loads(hook_json)
        valid_event = isinstance(event, dict)
    except (TypeError, ValueError, json.JSONDecodeError):
        event, valid_event = None, False
    if not valid_event:
        return _result("UNKNOWN_ALLOW", "invalid_input")
    if event.get("hook_event_name") != "Stop":
        return _result("OFF", "unsupported_event", _observation("skipped_unsupported_event"))
    turn_id = event.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id:
        return _result("UNKNOWN_ALLOW", "turn_id_unavailable")

    identity = {
        "run_id": environ.get("MULTICA_TASK_ID"),
        "agent_id": environ.get("MULTICA_AGENT_ID"),
        "workspace_id": environ.get("MULTICA_WORKSPACE_ID"),
    }
    if not all(isinstance(value, str) and value for value in identity.values()):
        return _result("UNKNOWN_ALLOW", "identity_missing")

    context = resolve_local_context(start_dir, environ)
    if context is None:
        return _result("UNKNOWN_ALLOW", "local_task_marker_unavailable")
    if context.agent_id is not None and context.agent_id != identity["agent_id"]:
        return _result("UNKNOWN_ALLOW", "local_task_marker_mismatch")

    comments_read = provider.fetch_comments(context.issue_id, identity["workspace_id"])
    if comments_read.value is None:
        return _result("UNKNOWN_ALLOW", comments_read.error or "comment_read_failed")
    if not comments_read.complete:
        return _result("UNKNOWN_ALLOW", "comment_read_incomplete")
    verdict = check_feedback(
        comments_read.value,
        identity["run_id"],
        identity["agent_id"],
        issue_id=context.issue_id,
    )
    result, reason = verdict["result"], verdict["reason"]
    if result in ("SUSPECT_MISSING_FEEDBACK", "SUSPECT_INCOMPLETE"):
        try:
            no_action = provider.has_no_action(context.issue_id, identity["workspace_id"], identity["run_id"])
        except Exception as error:
            return _result("UNKNOWN_ALLOW", f"timeline_read_failed:{type(error).__name__}")
        if no_action.value is None or not no_action.complete:
            return _result("UNKNOWN_ALLOW", no_action.error or "timeline_read_incomplete")
        if no_action.value is True:
            return _result("ALLOW", "no_action_verified_allow")
    if result in ("SUSPECT_MISSING_FEEDBACK", "SUSPECT_INCOMPLETE"):
        try:
            attempt = _record_block(identity["run_id"], turn_id, environ)
        except (OSError, ValueError, sqlite3.Error):
            return _result("UNKNOWN_ALLOW", "unknown_allow_state_unavailable")
        if attempt > MAX_BLOCKS:
            return _result("ALLOW", "retry_exhausted_allow", {"identity_trust": "unverified", **verdict})
        return _result("block", f"missing_feedback_block_{attempt}/3: {_block_reason(result)}", {"identity_trust": "unverified", **verdict})
    if result == "NORMAL_INTENTIONAL_END":
        return _result("ALLOW", "uep_verified_allow", {"identity_trust": "unverified", **verdict})
    return _result("UNKNOWN_ALLOW", reason, {"identity_trust": "unverified", **verdict})

def _record_block(run_id, turn_id, environ):
    state_path = Path(environ.get("MULTICA_GUARD_STATE") or Path.home() / ".multica" / "guard-stop-budget.sqlite3")
    if len(run_id) > 128 or len(turn_id) > 128:
        raise ValueError("state key too long")
    state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_path.parent, 0o700)
    descriptor = os.open(state_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    key = hashlib.sha256(json.dumps([run_id, turn_id], separators=(",", ":")).encode()).hexdigest()
    now = int(time.time())
    with sqlite3.connect(str(state_path), timeout=0.25) as connection:
        os.chmod(state_path, 0o600)
        connection.execute("PRAGMA busy_timeout=250")
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("CREATE TABLE IF NOT EXISTS stop_budget (key TEXT PRIMARY KEY, count INTEGER NOT NULL, updated INTEGER NOT NULL)")
        connection.execute("DELETE FROM stop_budget WHERE updated < ?", (now - STATE_TTL_SECONDS,))
        exists = connection.execute("SELECT 1 FROM stop_budget WHERE key=?", (key,)).fetchone()
        if not exists and connection.execute("SELECT COUNT(*) FROM stop_budget").fetchone()[0] >= 4096:
            raise sqlite3.OperationalError("state capacity reached")
        connection.execute("INSERT INTO stop_budget VALUES (?, 1, ?) ON CONFLICT(key) DO UPDATE SET count=count+1, updated=excluded.updated", (key, now))
        return connection.execute("SELECT count FROM stop_budget WHERE key=?", (key,)).fetchone()[0]

def _block_reason(result):
    if result == "SUSPECT_MISSING_FEEDBACK":
        return "本轮缺少可核验的 UEP 正式反馈；请只如实补交规范 Issue Comment，未完成不得谎称 DELIVERED；勿重跑原任务、发新任务或仅自然语言回复。"
    return "本轮 UEP 正式反馈不完整；请只如实补交规范 Issue Comment，未完成不得谎称 DELIVERED；勿重跑原任务、发新任务或仅自然语言回复。"


def main(argv=None):
    """Read one bounded Stop payload and print the Codex Stop protocol."""
    import argparse

    parser = argparse.ArgumentParser(description="Multica UEP Stop Hook")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--details", action="store_true")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    if not args.check:
        print(json.dumps({"continue": True, "decision": "OFF", "reason": "check_not_requested"}))
        return 0
    raw = sys.stdin.buffer.read(MAX_HOOK_BYTES + 1)
    if len(raw) > MAX_HOOK_BYTES:
        result = _result("UNKNOWN_ALLOW", "invalid_input")
    else:
        try:
            provider = MulticaReadOnlyProvider()
            result = shadow_observe(raw.decode("utf-8"), os.environ, provider)
        except Exception:
            result = _result("UNKNOWN_ALLOW", "provider_unexpected_error")
    output = result["hook_output"]
    if args.details:
        output = {"hook_output": output, "guard_decision": result["guard_decision"]}
    print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

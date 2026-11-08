#!/usr/bin/env python3
"""Bounded active Stop guard for the Codex Stop hook entry point.

The wrapper only turns an explicit ``decision: block`` from the guard into the
Codex Stop protocol.  Every timeout, startup, parse and logging failure prints
``{"continue": true}``: uncertainty never blocks a Stop.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_GUARD_SCRIPT = Path(__file__).resolve().with_name("guard_vnext.py")
DEFAULT_LOG_PATH = Path.home() / ".multica" / "guard-vnext-shadow.jsonl"
MAX_HOOK_BYTES = 65536
OBSERVER_SUBPROCESS_TIMEOUT_SECONDS = 7.0
SUGGESTED_HOOK_TIMEOUT_SECONDS = 8.0
MAX_LOG_BYTES = 256 * 1024
REASON_MAX_CHARS = 500

def evaluate(
    environ=None,
    guard_script=DEFAULT_GUARD_SCRIPT,
    subprocess_timeout=OBSERVER_SUBPROCESS_TIMEOUT_SECONDS,
    max_log_bytes=MAX_LOG_BYTES,
):
    """Run guard --check once, persist a minimal record, return the hook output.

    stdin is forwarded but never copied into the result or log.  The returned
    ``output`` is what the Stop hook must print; a record that is missing,
    malformed or carries any other decision is allow-only.
    """
    environ = os.environ if environ is None else environ
    raw = sys.stdin.buffer.read(MAX_HOOK_BYTES + 1)
    try:
        completed = subprocess.run(
            [sys.executable, str(guard_script), "--check", "--details"],
            input=raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=subprocess_timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return _fail_open(environ, "observer_timeout", max_log_bytes)
    except (OSError, subprocess.SubprocessError):
        return _fail_open(environ, "observer_start_failed", max_log_bytes)

    try:
        if completed.returncode != 0:
            raise ValueError("guard exit status")
        hook = json.loads(completed.stdout.decode("utf-8"))
        if not isinstance(hook, dict):
            raise ValueError("invalid guard result")
        details = hook.get("guard_decision")
        if isinstance(hook.get("hook_output"), dict) and isinstance(details, dict):
            output, guard_decision, guard_reason = _normalize(hook["hook_output"])
            detail_decision, detail_reason = details.get("decision"), details.get("reason")
            if detail_decision not in ("ALLOW", "UNKNOWN_ALLOW", "OFF", "block"):
                raise ValueError("invalid guard decision metadata")
            if not isinstance(detail_reason, str) or not detail_reason.strip():
                raise ValueError("invalid guard reason metadata")
            if (detail_decision == "block") != (output.get("decision") == "block"):
                raise ValueError("guard metadata does not match hook output")
            guard_decision = detail_decision.lower()
            guard_reason = (detail_reason.split(":", 1)[0]
                            if detail_reason.startswith("missing_feedback_block_")
                            else detail_reason)
        else:
            output, guard_decision, guard_reason = _normalize(hook)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError):
        return _fail_open(environ, "guard_invalid_output", max_log_bytes)

    record = _record(guard_decision, guard_reason, run_id=environ.get("MULTICA_TASK_ID"))
    _write_record(environ, record, max_log_bytes)
    return output, guard_decision, guard_reason

def _normalize(hook):
    """Map one guard output to ``(hook_output, decision, reason)``."""
    if hook.get("decision") == "block":
        reason = hook.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("block without reason")
        return (
            {"decision": "block", "reason": reason[:REASON_MAX_CHARS]},
            "block",
            reason.split(":", 1)[0] if reason.startswith("missing_feedback_block_") else "uep_feedback_not_verified",
        )
    if set(hook) == {"continue"} and hook["continue"] is True:
        return {"continue": True}, "allow", "allow_reason_unavailable"
    raise ValueError("unexpected guard output")

def _fail_open(environ, reason, max_log_bytes):
    record = _record("UNKNOWN_ALLOW", reason, run_id=environ.get("MULTICA_TASK_ID"))
    _write_record(environ, record, max_log_bytes)
    return {"continue": True}, "UNKNOWN_ALLOW", reason

def _record(guard_decision, guard_reason, run_id=None):
    """Only decision, reason, UTC and candidate Run ID; never prompt text."""
    return {
        "guard_decision": guard_decision,
        "guard_reason": guard_reason,
        "utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "run_id": run_id if isinstance(run_id, str) and run_id else None,
    }

def _write_record(environ, record, max_log_bytes):
    encoded = (json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    if len(encoded) > max_log_bytes:
        return False
    log_path = Path(environ.get("MULTICA_GUARD_SHADOW_LOG") or DEFAULT_LOG_PATH)
    try:
        log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(log_path.parent, 0o700)
        descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            if os.fstat(descriptor).st_size + len(encoded) > max_log_bytes:
                os.ftruncate(descriptor, 0)
            remaining = encoded
            while remaining:
                written = os.write(descriptor, remaining)
                remaining = remaining[written:]
        finally:
            os.close(descriptor)
    except OSError:
        return False
    return True

def main():
    guard_script = Path(os.environ.get("MULTICA_GUARD_VNEXT_SCRIPT") or DEFAULT_GUARD_SCRIPT)
    output, _, _ = evaluate(
        environ=os.environ,
        guard_script=guard_script,
        subprocess_timeout=OBSERVER_SUBPROCESS_TIMEOUT_SECONDS,
    )
    print(json.dumps(output, separators=(",", ":")))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

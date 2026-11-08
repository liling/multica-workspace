"""Bounded read-only access to the Multica CLI for active Stop Guard."""
import json
import os
import subprocess
import tempfile
import time
import uuid
from collections import namedtuple
from pathlib import Path


MAX_LOCAL_MARKER_BYTES = 4096
MAX_JSON_BYTES = 1024 * 1024
MAX_STDERR_BYTES = 64 * 1024
# Bound both read-only queries and leave observer/Hook startup and logging
# headroom inside the eight-second Codex Stop timeout.
CLI_TIMEOUT_SECONDS = 2.0
MAX_CLI_CALLS_PER_STOP = 2
TOTAL_BUDGET_SECONDS = 4.0

ProviderRead = namedtuple("ProviderRead", "value complete error")


class LocalTaskContext(namedtuple(
    "LocalTaskContext", "issue_id agent_id root"
)):
    pass


def resolve_local_context(start_dir=None, environ=None):
    """Read a local daemon marker only to choose a candidate Issue."""
    environ = os.environ if environ is None else environ
    run_id = environ.get("MULTICA_TASK_ID")
    agent_id = environ.get("MULTICA_AGENT_ID")
    workspace_id = environ.get("MULTICA_WORKSPACE_ID")
    if not all(isinstance(value, str) and value for value in (run_id, agent_id, workspace_id)):
        return None

    path = Path(start_dir or os.getcwd()).resolve()
    context_path = _find_ancestor(
        path, Path(".multica") / "daemon_task_context.json"
    )
    if context_path is None:
        return None
    try:
        context = _read_json(context_path, MAX_LOCAL_MARKER_BYTES)
        issue_id = context.get("issue_id")
        marker_agent_id = context.get("agent_id")
        if not _is_uuid(issue_id):
            return None
        if marker_agent_id is not None and marker_agent_id != agent_id:
            return None
        return LocalTaskContext(
            issue_id, marker_agent_id, context_path.parent.parent
        )
    except (OSError, ValueError, json.JSONDecodeError):
        return None


class MulticaReadOnlyProvider:
    def __init__(
        self, cli="multica", timeout_seconds=CLI_TIMEOUT_SECONDS,
        total_budget_seconds=TOTAL_BUDGET_SECONDS,
    ):
        self.cli = cli
        self.timeout_seconds = timeout_seconds
        self.total_budget_seconds = total_budget_seconds
        self.calls = 0
        self.spent = 0.0

    def _budget(self):
        """Return ``(timeout, None)`` for the next call or ``(None, reason)``."""
        if self.calls >= MAX_CLI_CALLS_PER_STOP:
            return None, "cli_call_limit_exceeded"
        remaining = self.total_budget_seconds - self.spent
        if remaining <= 0:
            return None, "cli_budget_exhausted"
        # Neither call may use more than its share of the shared Stop budget;
        # this also leaves time for the observer to persist its result.
        share = self.total_budget_seconds / MAX_CLI_CALLS_PER_STOP
        timeout = min(self.timeout_seconds, share, remaining)
        if timeout <= 0:
            return None, "cli_budget_exhausted"
        return timeout, None

    def _read(self, argv):
        timeout, exhausted = self._budget()
        if timeout is None:
            return ProviderRead(None, False, exhausted)
        self.calls += 1
        started = time.monotonic()
        try:
            return _bounded_json(argv, timeout)
        finally:
            self.spent += time.monotonic() - started

    def fetch_comments(self, issue_id, workspace_id):
        argv = [
            self.cli, "--workspace-id", workspace_id, "issue", "comment",
            "list", issue_id, "--full", "--output", "json",
        ]
        read = self._read(argv)
        if read.value is None:
            return read
        if not isinstance(read.value, list):
            return ProviderRead(None, False, "comments_read_invalid")
        return ProviderRead(read.value, read.complete, read.error)

    def has_no_action(self, issue_id, workspace_id, run_id):
        argv = [
            self.cli, "--workspace-id", workspace_id, "issue", "timeline",
            issue_id, "--action", "squad_leader_evaluated", "--tail", "50",
            "--output", "json",
        ]
        read = self._read(argv)
        if read.value is None or not read.complete:
            return ProviderRead(None, False, read.error or "timeline_incomplete")
        events = read.value
        if isinstance(events, dict):
            if (events.get("truncated") is True or events.get("has_more") is True
                    or events.get("next_cursor")):
                return ProviderRead(None, False, "timeline_truncated")
            events = events.get("items")
        if not isinstance(events, list):
            return ProviderRead(None, False, "timeline_invalid")
        if len(events) >= 50:
            return ProviderRead(None, False, "timeline_window_full")
        for event in events:
            if (not isinstance(event, dict)
                    or event.get("action") != "squad_leader_evaluated"
                    or not isinstance(event.get("details"), dict)):
                return ProviderRead(None, False, "timeline_record_invalid")
            details = event["details"]
            if not isinstance(details.get("task_id"), str) or details.get("outcome") not in ("action", "no_action", "failed"):
                return ProviderRead(None, False, "timeline_record_invalid")
            if details.get("task_id") == run_id and details.get("outcome") == "no_action":
                return ProviderRead(True, True, None)
        return ProviderRead(False, True, None)


def _is_uuid(value):
    if not isinstance(value, str):
        return False
    try:
        uuid.UUID(value)
    except (ValueError, TypeError):
        return False
    return True


def _read_json(path, max_bytes):
    raw = path.read_bytes()
    if len(raw) > max_bytes:
        raise ValueError("marker too large")
    return json.loads(raw.decode("utf-8"))


def _find_ancestor(path, relative):
    for root in (path, *path.parents):
        candidate = root / relative
        if candidate.is_file():
            return candidate
    return None


def _bounded_json(argv, timeout_seconds):
    try:
        stdout_file = tempfile.TemporaryFile()
        stderr_file = tempfile.TemporaryFile()
    except (OSError, subprocess.SubprocessError) as error:
        return ProviderRead(None, False, f"cli_start_failed:{type(error).__name__}")

    process = None
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
        )
        deadline = time.monotonic() + timeout_seconds
        while process.poll() is None:
            if stdout_file.tell() > MAX_JSON_BYTES or stderr_file.tell() > MAX_STDERR_BYTES:
                return _terminate_read(process, "output_limit_exceeded")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return _terminate_read(process, "cli_timeout")
            time.sleep(min(0.02, remaining))
        if process.poll() is None:
            return _terminate_read(process, "cli_timeout")
        returncode = process.wait()
        if returncode != 0:
            return ProviderRead(None, False, f"cli_exit_{returncode}")
        stdout_size, stderr_size = stdout_file.tell(), stderr_file.tell()
        if stdout_size > MAX_JSON_BYTES or stderr_size > MAX_STDERR_BYTES:
            return ProviderRead(None, False, "output_limit_exceeded")
        stderr_file.seek(0)
        stdout_file.seek(0)
        stderr = stderr_file.read(MAX_STDERR_BYTES).decode("utf-8", "replace")
        stderr_lower = stderr.lower()
        complete = not any(marker in stderr_lower for marker in (
            "next thread cursor", "next reply cursor", "response was truncated",
            "timeline truncated", "truncated", "truncation",
        ))
        value = json.loads(stdout_file.read(MAX_JSON_BYTES).decode("utf-8"))
        return ProviderRead(value, complete, None)
    except subprocess.TimeoutExpired:
        return _terminate_read(process, "cli_timeout")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return ProviderRead(None, False, f"cli_read_failed:{type(error).__name__}")
    finally:
        stdout_file.close()
        stderr_file.close()


def _terminate_read(process, error):
    if process is not None and process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    return ProviderRead(None, False, error)

"""Read-only, fail-open Run identity eligibility check; not a completion guard."""
import json
import tomllib
from pathlib import Path

try:
    from .uep_feedback import check_feedback
except ImportError:  # scripts and tests run this directory directly
    from uep_feedback import check_feedback

MAX_CONFIG_BYTES = 16384


def load_config(path):
    raw = Path(path).read_bytes()
    if len(raw) > MAX_CONFIG_BYTES:
        raise ValueError("config too large")
    config = json.loads(raw) if Path(path).suffix.lower() == ".json" else tomllib.loads(raw.decode("utf-8"))
    if not isinstance(config, dict) or set(config) != {"allowlist"}:
        raise ValueError("invalid config shape")
    allowlist = config["allowlist"]
    if not isinstance(allowlist, list):
        raise ValueError("allowlist must be a list")
    required = {"workspace_id", "run_id", "agent_id"}
    for entry in allowlist:
        if not isinstance(entry, dict) or set(entry) != required or any(
            not isinstance(entry[key], str) or not entry[key] for key in required
        ):
            raise ValueError("invalid allowlist entry")
    return allowlist


def evaluate(hook_json, environ, allowlist, provider):
    """Return minimal decision. provider(identity) must perform a trusted read."""
    try:
        event = json.loads(hook_json)
        if not isinstance(event, dict) or event.get("hook_event_name") not in (
            "Stop", "UserPromptSubmit"
        ):
            return {"decision": "OFF", "reason": "unsupported_event"}
        identity = {"run_id": environ.get("MULTICA_TASK_ID"),
                    "agent_id": environ.get("MULTICA_AGENT_ID"),
                    "workspace_id": environ.get("MULTICA_WORKSPACE_ID")}
        if not all(identity.values()):
            return {"decision": "UNKNOWN_ALLOW", "reason": "identity_missing"}
        if not any(all(identity[k] == item[k] for k in identity) for item in allowlist):
            return {"decision": "OFF", "reason": "not_opted_in"}
        current = provider(identity)
        if not isinstance(current, dict) or current.get("status") != "running":
            return {"decision": "UNKNOWN_ALLOW", "reason": "run_not_active_or_unknown"}
        if not all(current.get(key) for key in identity) or any(
            current.get(key) != value for key, value in identity.items()
        ):
            return {"decision": "UNKNOWN_ALLOW", "reason": "identity_mismatch"}
        attestation = current.get("current_execution_attestation")
        if not isinstance(attestation, dict):
            return {"decision": "UNKNOWN_ALLOW", "reason": "execution_binding_unproven"}
        if attestation.get("hook_event") != event.get("hook_event_name"):
            return {"decision": "UNKNOWN_ALLOW", "reason": "execution_binding_unproven"}
        if not all(attestation.get(key) == value for key, value in identity.items()):
            return {"decision": "UNKNOWN_ALLOW", "reason": "identity_mismatch"}
        if not current.get("issue_id"):
            return {"decision": "UNKNOWN_ALLOW", "reason": "issue_unavailable"}
        return {"decision": "ELIGIBLE_DRY_RUN", "reason": "explicit_run_opt_in", "issue_id": current["issue_id"]}
    except Exception:
        return {"decision": "UNKNOWN_ALLOW", "reason": "invalid_input_or_provider_error"}

def evaluate_vnext(
    hook_json, environ, allowlist, provider, comments_provider, comments_complete
):
    """Run ShouldCheck, then CheckFeedback only for an eligible Stop event.

    ``comments_provider(issue_id)`` must return the complete current-Issue
    Comment read, including ``source_task_id`` and ``author_id``.  Dry-run
    callers must independently map every returned decision to allow.
    """
    try:
        event = json.loads(hook_json)
        if not isinstance(event, dict) or event.get("hook_event_name") != "Stop":
            return {"decision": "OFF", "reason": "unsupported_event"}
        if event.get("stop_hook_active") is True:
            return {"decision": "OFF", "reason": "stop_hook_reentry"}
    except Exception:
        return {"decision": "UNKNOWN_ALLOW", "reason": "invalid_input"}

    eligibility = evaluate(hook_json, environ, allowlist, provider)
    if eligibility["decision"] != "ELIGIBLE_DRY_RUN":
        return eligibility
    if not comments_complete:
        return {"decision": "UNKNOWN_ALLOW", "reason": "comment_read_incomplete"}
    try:
        issue_id = eligibility["issue_id"]
        comments = comments_provider(issue_id)
    except Exception:
        return {"decision": "UNKNOWN_ALLOW", "reason": "comments_provider_error"}
    identity = {
        "run_id": environ["MULTICA_TASK_ID"],
        "agent_id": environ["MULTICA_AGENT_ID"],
    }
    verdict = check_feedback(comments, **identity)
    return {"decision": verdict.pop("result"), "reason": verdict.pop("reason"), **verdict}


def guard(path, hook_json, environ, provider):
    """Compose loading and evaluation; every error is fail-open, never block."""
    try:
        return evaluate(hook_json, environ, load_config(path), provider)
    except Exception:
        return {"decision": "UNKNOWN_ALLOW", "reason": "config_load_failed"}


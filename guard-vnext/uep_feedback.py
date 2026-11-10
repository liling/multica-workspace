"""Deterministic UEP_FEEDBACK/1 Comment checker for UEP v0.5 draft.

The checker has no model, no semantic scoring and no network access.  It only
accepts Comments whose provider has already associated them with the current
Issue, ``source_task_id`` and ``author_id``.
"""
import re
from datetime import datetime

MARKER = "UEP_FEEDBACK: 1"
MAX_COMMENTS = 500
STATES = ("RUN_UNIT_DONE", "DELIVERED", "BLOCKED", "NEEDS_DECISION")
NEXT_KINDS = ("NONE", "HANDOFF", "WAIT")

AGENT_MENTION = re.compile(r"\[@([^\]\n]+)\]\(mention://agent/([^)\s]+)\)")
AGENT_MENTION_TEXT = "mention://agent/"
UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
FIELD_LINE = re.compile(r"^(STATE|RESULT|NEXT):(.*)$")


def check_feedback(comments, run_id, agent_id, issue_id=None):
    """Check the one UEP Comment persisted by this Run and Agent.

    ``comments`` must be the complete, current-Issue Comment read supplied by
    a trusted, read-only provider.  A missing source association is unknown,
    never an automatic pass or block.
    """
    if not isinstance(comments, (list, tuple)):
        return _unknown("comments_not_a_list")
    if len(comments) > MAX_COMMENTS:
        return _unknown("comment_read_too_large")
    try:
        associated, marker_comments = [], []
        for comment in comments:
            if not isinstance(comment, dict):
                return _unknown("comment_record_invalid")
            author_id = comment.get("author_id")
            if not isinstance(author_id, str) or not author_id:
                return _unknown("author_id_unavailable")
            if author_id != agent_id:
                continue
            source_task_id = comment.get("source_task_id")
            if not isinstance(source_task_id, str) or not source_task_id:
                return _unknown("source_task_id_unavailable")
            if source_task_id != run_id:
                continue
            comment_id = comment.get("id")
            if not isinstance(comment_id, str) or not comment_id:
                return _unknown("comment_id_unavailable")
            record_type = comment.get("type")
            if not isinstance(record_type, str) or not record_type:
                return _unknown("comment_type_unavailable")
            if record_type == "activity" or record_type == "event":
                continue
            if record_type != "comment":
                return _unknown("comment_type_unavailable")
            if not isinstance(comment.get("content"), str):
                return _unknown("content_unavailable")
            if issue_id is not None:
                comment_issue_id = comment.get("issue_id")
                if not isinstance(comment_issue_id, str) or not comment_issue_id:
                    return _unknown("issue_id_unavailable")
                if comment_issue_id != issue_id:
                    return _unknown("comment_issue_mismatch")
            associated.append(comment)
            if _is_marker_comment(comment):
                marker_comments.append(comment)
    except Exception:
        return _unknown("comments_read_error")

    if not associated:
        return {"result": "SUSPECT_MISSING_FEEDBACK", "reason": "run_feedback_missing"}
    if not marker_comments:
        return {
            "result": "SUSPECT_MISSING_FEEDBACK",
            "reason": "uep_marker_missing",
            "run_comment_ids": _ids(associated),
        }
    if not _has_selection_metadata(marker_comments):
        return _unknown("selection_metadata_invalid")
    if len(marker_comments) > 1:
        selected, conflict_reason = _select_newest(marker_comments)
        if selected is None:
            return _unknown(conflict_reason)
        selection = {
            "selection_rule": "newest_created_at_then_comment_id",
            "feedback_comment_count": len(marker_comments),
        }
    else:
        selected = marker_comments[0]
        selection = {"feedback_comment_count": 1}
    verdict, fields = parse_comment(_text(selected))
    parsed = {"feedback_comment_id": selected.get("id"), **(fields or {})}
    return {**verdict, **selection, **parsed}


def parse_comment(content):
    """Parse one persisted Comment body against the four fixed UEP lines.

    ``STATE``, ``RESULT`` and ``NEXT`` must be consecutive lines. Evidence
    belongs after ``NEXT``; extra lines between fields invalidate the body.
    """
    if not isinstance(content, str):
        return _incomplete("comment_not_text"), None
    lines = content.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    index = 0
    while index < len(lines) and not lines[index].strip():
        index += 1
    if index >= len(lines) or lines[index].rstrip() != MARKER:
        return _incomplete("missing_marker"), None

    fields = {}
    for expected in ("STATE", "RESULT", "NEXT"):
        index += 1
        if index >= len(lines):
            return _incomplete(f"missing_{expected.lower()}_line"), None
        match = FIELD_LINE.match(lines[index].strip())
        if not match or match.group(1) != expected:
            reason = "duplicate_marker" if lines[index].strip() == MARKER else f"malformed_{expected.lower()}_line"
            return _incomplete(reason), None
        fields[expected] = match.group(2).strip()

    state, result, next_kind = fields["STATE"], fields["RESULT"], fields["NEXT"]
    if state not in STATES:
        return _incomplete("invalid_state"), None
    if not result:
        return _incomplete("empty_result"), None
    if next_kind not in NEXT_KINDS:
        return _incomplete("invalid_next"), None

    tail = "\n".join(lines[index + 1 :]).strip()
    mentions, mention_reason = _agent_mentions(tail)
    if mention_reason:
        return _incomplete(mention_reason), None
    target_agent_id = None
    if next_kind == "HANDOFF":
        if not mentions:
            return _incomplete("handoff_target_missing"), None
        if len(mentions) > 1:
            return _incomplete("handoff_target_ambiguous"), None
        target_agent_id = mentions[0][1]
        if not UUID_PATTERN.fullmatch(target_agent_id):
            return _incomplete("handoff_target_invalid_uuid"), None
        if not AGENT_MENTION.sub(" ", tail).strip():
            return _incomplete("handoff_text_empty"), None
    elif mentions:
        return _incomplete("unexpected_agent_mention"), None
    elif next_kind == "WAIT":
        wait_reason = _wait_reason(tail)
        if wait_reason:
            return _incomplete(wait_reason), None

    parsed = {
        "state": state,
        "next": next_kind,
        "target_agent_id": target_agent_id,
    }
    return {"result": "NORMAL_INTENTIONAL_END", "reason": "uep_feedback_valid"}, parsed


def _is_marker_comment(comment):
    for line in _text(comment).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.strip():
            return line.rstrip() == MARKER
    return False


def _text(comment):
    content = comment.get("content")
    return content if isinstance(content, str) else ""


def _ids(comments):
    return [comment.get("id") for comment in comments]


def _has_selection_metadata(comments):
    try:
        return all(
            isinstance(comment.get("id"), str)
            and bool(comment.get("id"))
            and _sort_key(comment) is not None
            for comment in comments
        )
    except Exception:
        return False


def _sort_key(comment):
    timestamp = datetime.fromisoformat(comment["created_at"].replace("Z", "+00:00"))
    if timestamp.tzinfo is None:
        raise ValueError("created_at is not timezone-aware")
    return timestamp, comment["id"]


def _select_newest(comments):
    try:
        selected = max(comments, key=_sort_key)
        return selected, None
    except Exception:
        return None, "feedback_selection_metadata_invalid"


def _agent_mentions(text):
    canonical = AGENT_MENTION.findall(text)
    raw_count = text.count(AGENT_MENTION_TEXT)
    if raw_count != len(canonical):
        return [], "malformed_agent_mention"
    return canonical, None


def _wait_reason(tail):
    if not tail:
        return "wait_statement_missing"
    return None


def _unknown(reason):
    return {"result": "UNKNOWN_ALLOW", "reason": reason}


def _incomplete(reason):
    return {"result": "SUSPECT_INCOMPLETE", "reason": reason}

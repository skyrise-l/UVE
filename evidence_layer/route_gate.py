"""P0 route gate for answer/exploration evidence separation.

This is a thin extraction of existing route-boundary rules.  It does not change the
main algorithm; it makes the answer/exploration eligibility decision explicit and
traceable for audits and future optimization.
"""

from __future__ import annotations

from collections import Counter
from typing import Any, Dict, Iterable, Mapping

from evidence_layer.evidence_contracts import (
    CURRENT_QUESTION_ROLE,
    EXECUTION_RECOVERY_PROVENANCE,
    EXPLORATION_ROLE,
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
    SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE,
    TRACE_FRONTIER_PROVENANCE,
    TRACE_RESULT_PROVENANCE,
)

ANSWER_FORBIDDEN_PROVENANCE = {
    EXECUTION_RECOVERY_PROVENANCE,
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
    SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE,
    TRACE_FRONTIER_PROVENANCE,
}

EXPLORATION_ALLOWED_PROVENANCE = {
    EXECUTION_RECOVERY_PROVENANCE,
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
    SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE,
    TRACE_FRONTIER_PROVENANCE,
    TRACE_RESULT_PROVENANCE,
}


_EXPLORATION_PROVENANCE_ALIASES = {
    # Raw trace plans are created before the route metadata is attached.
    "veg_table": TRACE_FRONTIER_PROVENANCE,
    "trace_result": TRACE_FRONTIER_PROVENANCE,
    "trace_result_computed": TRACE_FRONTIER_PROVENANCE,
    "trace_frontier": TRACE_FRONTIER_PROVENANCE,
    "computed_join_probe": JOIN_PROBE_PROVENANCE,
    "join_probe": JOIN_PROBE_PROVENANCE,
}


def canonical_exploration_provenance(item: Mapping[str, Any]) -> str:
    """Resolve raw plan metadata to the canonical exploration provenance.

    Visual plans are generated before P0 route metadata is attached.  The previous
    implementation gated raw ``veg_table``/``computed_join_probe`` sources and only
    assigned canonical provenance after selection, which rejected every computed
    frontier.  Canonicalization must therefore happen before the legality decision.
    """
    plan = dict(item or {})
    explicit = str(plan.get("provenance") or "").strip()
    faithfulness_source = str(dict(plan.get("faithfulness") or {}).get("source") or "").strip()
    raw = explicit or faithfulness_source

    if bool(plan.get("join_probe")) or raw in {"computed_join_probe", "join_probe", JOIN_PROBE_PROVENANCE}:
        return JOIN_PROBE_PROVENANCE
    if raw in EXPLORATION_ALLOWED_PROVENANCE:
        return raw
    if raw in _EXPLORATION_PROVENANCE_ALIASES:
        return _EXPLORATION_PROVENANCE_ALIASES[raw]
    # Missing provenance is not guessed from generic fields such as plan_id/source_tid.
    # The caller must attach provenance from the architectural input channel.
    return raw


def answer_route_decision(item: Mapping[str, Any]) -> Dict[str, Any]:
    """Decide whether an item may support the current-question answer route."""
    plan = dict(item or {})
    provenance = str(plan.get("provenance") or (dict(plan.get("faithfulness") or {}).get("source") or "")).strip()
    if bool(plan.get("exploration_only")):
        return _decision(False, "exploration_only", provenance, plan)
    if bool(plan.get("join_probe")):
        return _decision(False, "computed_join_probe_is_exploration_only", provenance or JOIN_PROBE_PROVENANCE, plan)
    if provenance in {"computed_join_probe", "join_probe"}:
        return _decision(False, "computed_join_probe_is_exploration_only", JOIN_PROBE_PROVENANCE, plan)
    if provenance in ANSWER_FORBIDDEN_PROVENANCE:
        return _decision(False, f"forbidden_answer_provenance:{provenance}", provenance, plan)
    role = str(plan.get("evidence_role") or "").strip()
    if role == EXPLORATION_ROLE:
        return _decision(False, "exploration_role", provenance, plan)
    return _decision(True, "current_trace_or_unmarked_computed_plan", provenance or TRACE_RESULT_PROVENANCE, plan)


def exploration_route_decision(
    item: Mapping[str, Any],
    *,
    expected_provenance: str = "",
) -> Dict[str, Any]:
    """Decide whether an item may serve as next-question exploration evidence.

    ``expected_provenance`` is supplied by the architectural input channel
    (trace-frontier list versus join-probe list).  This avoids permissively inferring
    provenance from generic plan fields and also detects candidates placed in the wrong
    channel.
    """
    plan = dict(item or {})
    expected = str(expected_provenance or "").strip()
    explicit = str(plan.get("provenance") or "").strip()

    # Outside a typed architectural channel, only an explicit canonical provenance is
    # trusted.  Raw visual source labels such as ``veg_table`` are implementation
    # details, not authorization to enter the exploration route.
    if not expected and explicit not in EXPLORATION_ALLOWED_PROVENANCE:
        reason = "missing_exploration_provenance" if not explicit else f"unknown_exploration_provenance:{explicit}"
        return _decision(False, reason, explicit, plan)

    provenance = canonical_exploration_provenance(plan)

    if not provenance and expected:
        provenance = expected
    if expected == TRACE_FRONTIER_PROVENANCE and provenance == TRACE_RESULT_PROVENANCE:
        provenance = TRACE_FRONTIER_PROVENANCE
    if expected and provenance != expected:
        actual = provenance or "missing"
        return _decision(
            False,
            f"exploration_channel_provenance_mismatch:{expected}:{actual}",
            provenance,
            plan,
        )
    if not provenance:
        return _decision(False, "missing_exploration_provenance", provenance, plan)
    if provenance not in EXPLORATION_ALLOWED_PROVENANCE:
        return _decision(False, f"unknown_exploration_provenance:{provenance}", provenance, plan)
    return _decision(True, "exploration_signal", provenance, plan)


def summarize_route_decisions(decisions: Iterable[Mapping[str, Any]], *, max_examples: int = 5) -> Dict[str, Any]:
    """Compact route-gate audit payload."""
    rows = [dict(item or {}) for item in list(decisions or [])]
    reasons = Counter(str(row.get("reason") or "") for row in rows if not bool(row.get("allowed")))
    return {
        "input_count": len(rows),
        "allowed_count": sum(bool(row.get("allowed")) for row in rows),
        "rejected_count": sum(not bool(row.get("allowed")) for row in rows),
        "rejection_reasons": dict(reasons),
        "rejected_examples": [
            {
                "id": str(row.get("id") or ""),
                "reason": str(row.get("reason") or ""),
                "provenance": str(row.get("provenance") or ""),
                "title": str(row.get("title") or ""),
            }
            for row in rows
            if not bool(row.get("allowed"))
        ][:max_examples],
    }


def _decision(allowed: bool, reason: str, provenance: str, item: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "allowed": bool(allowed),
        "reason": str(reason or ""),
        "provenance": str(provenance or ""),
        "id": str((item or {}).get("plan_id") or (item or {}).get("id") or ""),
        "title": str((item or {}).get("title") or (item or {}).get("pattern") or ""),
    }
